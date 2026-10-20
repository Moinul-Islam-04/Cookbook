"""Import limits: per user per hour and per day, plus a global daily kill switch.

Counted from import_drafts rows in PostgreSQL; a rejected request never reaches the
extractor (each extraction costs money).
"""

import uuid
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

from app.config import DEV_USER_ID
from app.extraction import FakeExtractor
from app.main import create_app
from app.deps import get_current_user_id
from tests import conftest
from tests.test_recipes_api import assert_error

CAPTION = "Toast: bread, butter. Toast the bread, then butter it."


@pytest.fixture
def limited_app(engine: Engine):
    app = create_app(conftest.test_settings(import_limit_per_hour=3, import_limit_per_day=5, import_limit_global_per_day=8))
    app.state.extractor = FakeExtractor()
    return app


@pytest.fixture
def limited_client(limited_app) -> TestClient:
    with TestClient(limited_app) as c:
        yield c


def act_as(app, user_id: uuid.UUID) -> None:
    app.dependency_overrides[get_current_user_id] = lambda: user_id


def add_drafts(engine: Engine, user_id: uuid.UUID, ages: list[timedelta]) -> None:
    """Drafts created `age` ago, as earlier imports would have left them."""
    now = datetime.now(UTC)
    with engine.begin() as conn:
        for age in ages:
            conn.execute(
                text(
                    "INSERT INTO import_drafts (user_id, source_text, content, extraction_version, created_at, updated_at, expires_at) "
                    "VALUES (:u, 'x', '{}', 'fake-1', :c, :c, :e)"
                ),
                {"u": user_id, "c": now - age, "e": now - age + timedelta(hours=24)},
            )


def import_caption(client: TestClient):
    return client.post("/v1/import-drafts", json={"source_text": CAPTION})


def assert_limited(res) -> int:
    body = assert_error(res, 429, "rate_limited")
    assert body["retryable"] is True
    assert "manually" in body["message"]
    return int(res.headers["Retry-After"])


def test_under_the_limits_imports(limited_app, limited_client: TestClient, engine: Engine) -> None:
    add_drafts(engine, DEV_USER_ID, [timedelta(minutes=5)] * 2)
    assert import_caption(limited_client).status_code == 201
    assert limited_app.state.extractor.calls == [CAPTION]


def test_hourly_limit(limited_app, limited_client: TestClient, engine: Engine) -> None:
    # The oldest of the three leaves the hour in 20 minutes.
    add_drafts(engine, DEV_USER_ID, [timedelta(minutes=40), timedelta(minutes=10), timedelta(minutes=1)])
    wait = assert_limited(import_caption(limited_client))
    assert 19 * 60 <= wait <= 20 * 60 + 1
    assert limited_app.state.extractor.calls == []  # never reached the extractor
    assert "hour" in import_caption(limited_client).json()["message"]


def test_drafts_older_than_an_hour_leave_the_hourly_count(limited_client: TestClient, engine: Engine) -> None:
    add_drafts(engine, DEV_USER_ID, [timedelta(minutes=61)] * 3 + [timedelta(minutes=1)])
    assert import_caption(limited_client).status_code == 201


def test_daily_limit(limited_app, limited_client: TestClient, engine: Engine) -> None:
    # Five today, none in the last hour; the oldest leaves the day in 2 hours.
    add_drafts(engine, DEV_USER_ID, [timedelta(hours=22), timedelta(hours=20), timedelta(hours=5), timedelta(hours=3), timedelta(hours=2)])
    wait = assert_limited(import_caption(limited_client))
    assert 2 * 3600 - 5 <= wait <= 2 * 3600 + 1
    assert limited_app.state.extractor.calls == []
    assert "day" in import_caption(limited_client).json()["message"]


def test_limits_are_per_user(limited_app, limited_client: TestClient, engine: Engine, make_user) -> None:
    add_drafts(engine, DEV_USER_ID, [timedelta(minutes=1)] * 3)
    assert_limited(import_caption(limited_client))
    act_as(limited_app, make_user())
    assert import_caption(limited_client).status_code == 201
    assert limited_app.state.extractor.calls == [CAPTION]


def test_global_daily_cap(limited_app, limited_client: TestClient, engine: Engine, make_user) -> None:
    # Eight drafts across four other users, each under their own limits.
    for _ in range(4):
        add_drafts(engine, make_user(), [timedelta(hours=12), timedelta(hours=6)])
    act_as(limited_app, make_user())  # a new user with no imports at all
    res = import_caption(limited_client)
    wait = assert_limited(res)
    assert "everyone" in res.json()["message"]
    assert 12 * 3600 - 5 <= wait <= 12 * 3600 + 1
    assert limited_app.state.extractor.calls == []


def test_successful_imports_count_towards_the_limit(limited_app, limited_client: TestClient) -> None:
    for _ in range(3):
        assert import_caption(limited_client).status_code == 201
    assert_limited(import_caption(limited_client))
    assert len(limited_app.state.extractor.calls) == 3


def test_default_limits() -> None:
    s = conftest.test_settings()
    assert (s.import_limit_per_hour, s.import_limit_per_day, s.import_limit_global_per_day) == (20, 100, 300)


def test_draft_expiry_shorter_than_a_day_is_refused(engine: Engine) -> None:
    # The daily count only sees drafts that still exist.
    with pytest.raises(RuntimeError, match="at least 24"):
        create_app(conftest.test_settings(draft_ttl_hours=12))
