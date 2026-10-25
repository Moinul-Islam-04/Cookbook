"""Stage 2: device payload → RawPost (app/ingest), and storing it with the draft.

Fixtures are saved payloads (tests/fixtures/posts); nothing contacts Instagram or TikTok.
"""

import json
import uuid
from datetime import UTC, datetime
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.cleanup import cleanup
from app.ingest import RawPost, normalize
from app.ingest.instagram import unwrap_preview
from app.schemas import ImportDraftCreate
from app.source_urls import parse_source_url
from tests.conftest import count
from tests.test_import_drafts import BRIEF_CAPTION, BRIEF_OUTPUT, make_draft, save_body, use_fake
from tests.test_recipes_api import assert_error

FIXTURES = sorted((Path(__file__).parent / "fixtures" / "posts").glob("*.json"))
TIKTOK_URL = "https://www.tiktok.com/@noodle.nina/video/7301234567890123456"


def normalize_payload(payload: dict) -> RawPost:
    body = ImportDraftCreate.model_validate(payload)
    return normalize(body, parse_source_url(body.source_url) if body.source_url else None)


@pytest.mark.parametrize("path", FIXTURES, ids=[p.stem for p in FIXTURES])
def test_fixture_normalizes_to_expected_raw_post(path: Path) -> None:
    case = json.loads(path.read_text())
    assert normalize_payload(case["payload"]) == RawPost.model_validate(case["expected"])


def test_fixtures_cover_both_platforms_and_pasted_text() -> None:
    platforms = {json.loads(p.read_text())["expected"]["platform"] for p in FIXTURES}
    assert platforms == {"instagram", "tiktok", None}


@pytest.mark.parametrize(
    "text, caption, handle",
    [
        ('10 likes, 0 comments - a on Jan 1, 2026: "Toast: bread, butter. Toast it."', "Toast: bread, butter. Toast it.", "a"),
        ('1.2K likes, 3 comments - b_b on March 9, 2025: "x"', "x", "b_b"),
        ("Chef Ann on Instagram: “Easy chili: 1 lb beef”", "Easy chili: 1 lb beef", None),
        ("Plain caption with a quote: \"hi\"", 'Plain caption with a quote: "hi"', None),
        ("See photos and videos from Chef Ann", "See photos and videos from Chef Ann", None),
    ],
)
def test_instagram_preview_text_is_unwrapped(text: str, caption: str, handle: str | None) -> None:
    got_caption, got_handle, _ = unwrap_preview(text)
    assert (got_caption, got_handle) == (caption, handle)


def test_explicit_device_fields_win_over_preview_text() -> None:
    raw = normalize_payload({
        "source_text": '5 likes, 1 comment - from.preview on May 1, 2026: "Soup"',
        "source_url": "https://www.instagram.com/p/C1a2B3c4D5e/",
        "author_handle": "from.device",
        "posted_at": "2026-05-02T10:00:00Z",
    })
    assert raw.author_handle == "from.device"
    assert raw.posted_at == datetime(2026, 5, 2, 10, tzinfo=UTC)
    assert raw.caption == "Soup"


def test_tiktok_preview_like_text_is_left_alone() -> None:
    # Instagram's preview format means nothing on TikTok; the caption stays as sent.
    text_ = '5 likes, 1 comment - x on May 1, 2026: "Soup"'
    assert normalize_payload({"source_text": text_, "source_url": TIKTOK_URL}).caption == text_


@pytest.mark.parametrize(
    "extra, field",
    [
        ({"top_comments": ["x"] * 21}, "top_comments"),
        ({"top_comments": ["x" * 2201]}, "top_comments.0"),
        ({"transcript": "x" * 20001}, "transcript"),
        ({"media_urls": ["http://cdn.example/a.jpg"]}, "media_urls.0"),
        ({"media_urls": ["javascript:alert(1)"]}, "media_urls.0"),
    ],
)
def test_device_extras_are_bounded(client: TestClient, extra: dict, field: str) -> None:
    res = client.post("/v1/import-drafts", json={"source_text": BRIEF_CAPTION, **extra})
    assert_error(res, 422, "invalid_request")
    assert field in [e["field"] for e in res.json()["field_errors"]]


def raw_post_rows(engine: Engine) -> list:
    with engine.connect() as conn:
        return conn.execute(text("SELECT * FROM raw_posts ORDER BY created_at")).all()


def test_draft_stores_the_raw_post_and_save_links_it(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    d = make_draft(
        client,
        BRIEF_CAPTION,
        source_url=TIKTOK_URL + "?is_from_webapp=1",
        transcript="Cook pasta, toss with tomatoes and oil.",
        top_comments=["so good", "recipe pls"],
        media_urls=["https://cdn.example/a.jpg"],
    )
    assert d["source_url"] == TIKTOK_URL
    [row] = raw_post_rows(engine)
    assert (row.platform, row.post_id, row.author_handle) == ("tiktok", "7301234567890123456", "noodle.nina")
    assert row.top_comments == ["so good", "recipe pls"]
    assert row.media_urls == ["https://cdn.example/a.jpg"]
    assert row.transcript == "Cook pasta, toss with tomatoes and oil."

    res = client.post("/v1/recipes", json=save_body(d))
    assert res.status_code == 201, res.text
    with engine.connect() as conn:
        draft_post, recipe_post = conn.execute(
            text("SELECT d.raw_post_id, r.raw_post_id FROM import_drafts d JOIN recipes r ON r.id = d.saved_recipe_id")
        ).one()
    assert draft_post == recipe_post == row.id
    assert "raw_post" not in json.dumps(res.json())  # never returned by the API


def test_tiktok_post_saved_twice_warns(app, client: TestClient) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    first = make_draft(client, BRIEF_CAPTION, source_url=TIKTOK_URL)
    assert client.post("/v1/recipes", json=save_body(first)).status_code == 201
    # Same video, different handle spelling in the link: the numeric ID is the identity.
    second = make_draft(client, BRIEF_CAPTION, source_url="https://m.tiktok.com/@nina/video/7301234567890123456")
    assert second["warnings"][0]["code"] == "duplicate_post"


@pytest.mark.parametrize("url", ["https://vm.tiktok.com/ZMabc123/", "https://www.tiktok.com/t/ZTabc123/"])
def test_short_tiktok_links_are_rejected_without_fetching(client: TestClient, url: str) -> None:
    res = client.post("/v1/import-drafts", json={"source_text": BRIEF_CAPTION, "source_url": url})
    assert_error(res, 422, "invalid_request")
    assert "Short TikTok links" in res.json()["field_errors"][0]["message"]


def test_cleanup_keeps_posts_of_saved_recipes_only(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    saved = make_draft(client, BRIEF_CAPTION)
    recipe_id = client.post("/v1/recipes", json=save_body(saved)).json()["id"]
    make_draft(client, BRIEF_CAPTION)  # abandoned
    with engine.begin() as conn:
        conn.execute(text("UPDATE import_drafts SET expires_at = now() - interval '1 second'"))
    with Session(engine) as s:
        assert cleanup(s)["raw_posts"] == 1
    assert count(engine, "raw_posts") == 1

    assert client.delete(f"/v1/recipes/{recipe_id}").status_code == 204
    with Session(engine) as s:
        assert cleanup(s)["raw_posts"] == 1
    assert count(engine, "raw_posts") == 0


def test_raw_post_identity_must_be_complete(engine: Engine, make_user) -> None:
    uid = make_user()
    with pytest.raises(IntegrityError, match="ck_raw_posts_identity_complete"), engine.begin() as conn:
        conn.execute(
            text("INSERT INTO raw_posts (user_id, platform, caption) VALUES (:u, 'tiktok', 'x')"), {"u": uid}
        )
    with pytest.raises(IntegrityError, match="ck_raw_posts_platform_valid"), engine.begin() as conn:
        conn.execute(
            text("INSERT INTO raw_posts (user_id, platform, post_id, url, caption) VALUES (:u, 'youtube', '1', 'u', 'x')"),
            {"u": uid},
        )


def test_deleting_a_user_deletes_their_raw_posts(engine: Engine, make_user) -> None:
    uid = make_user()
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO raw_posts (id, user_id, caption) VALUES (:id, :u, 'x')"), {"id": uuid.uuid4(), "u": uid})
        conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": uid})
    assert count(engine, "raw_posts") == 0
