"""auth_mode=token: device tokens, ownership, forged/expired/revoked tokens."""

import base64
import json
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.orm import Session

from app.auth import PAIRING_PREFIX, issue_token, pairing_code
from app.config import Settings
from app.main import create_app
from tests.conftest import TEST_DATABASE_URL
from tests.test_recipes_api import TOMATO_PASTA, assert_error


@pytest.fixture
def token_app(engine: Engine):
    return create_app(Settings(database_url=TEST_DATABASE_URL, auth_mode="token"))


@pytest.fixture
def anon(token_app):
    with TestClient(token_app) as c:
        yield c


def make_token(engine: Engine, user_id, lifetime=timedelta(days=1)) -> str:
    with Session(engine) as s:
        _, token = issue_token(s, user_id, "test device", lifetime)
        s.commit()
    return token


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_every_api_route_requires_a_token(anon: TestClient) -> None:
    for method, path in [
        ("GET", "/v1/recipes"),
        ("POST", "/v1/recipes"),
        ("GET", "/v1/recipes/00000000-0000-0000-0000-000000000000"),
        ("POST", "/v1/import-drafts"),
    ]:
        body = assert_error(anon.request(method, path, json={}), 401, "unauthenticated")
        assert "Pair it in Settings" in body["message"]
    assert anon.get("/healthz").status_code == 200  # reachability check stays open


def test_valid_token_works_and_records_last_use(anon: TestClient, engine: Engine, make_user) -> None:
    uid = make_user()
    token = make_token(engine, uid)
    res = anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(token))
    assert res.status_code == 201
    assert anon.get("/v1/recipes", headers=auth(token)).json()["items"][0]["id"] == res.json()["id"]
    with engine.connect() as c:
        assert c.execute(text("SELECT last_used_at IS NOT NULL FROM api_tokens")).scalar_one()


@pytest.mark.parametrize(
    "header",
    [
        "Bearer ckb_forged-token-that-was-never-issued",
        "Bearer not-even-our-format",
        "Basic dXNlcjpwYXNz",
        "Bearer",
        "",
    ],
)
def test_forged_or_malformed_tokens_fail(anon: TestClient, header: str) -> None:
    assert_error(anon.get("/v1/recipes", headers={"Authorization": header}), 401, "unauthenticated")


def test_expired_and_revoked_tokens_fail(anon: TestClient, engine: Engine, make_user) -> None:
    uid = make_user()
    expired = make_token(engine, uid, lifetime=timedelta(seconds=-1))
    assert_error(anon.get("/v1/recipes", headers=auth(expired)), 401, "unauthenticated")
    revoked = make_token(engine, uid)
    assert anon.get("/v1/recipes", headers=auth(revoked)).status_code == 200
    with engine.begin() as c:
        c.execute(text("UPDATE api_tokens SET revoked_at = now() WHERE expires_at > now()"))
    assert_error(anon.get("/v1/recipes", headers=auth(revoked)), 401, "unauthenticated")


def test_users_cannot_reach_each_others_data(anon: TestClient, engine: Engine, make_user) -> None:
    a, b = make_user(), make_user()
    ta, tb = make_token(engine, a), make_token(engine, b)
    rid = anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(ta)).json()["id"]
    did = anon.post("/v1/import-drafts", json={"source_text": "Toast\nIngredients\n- bread\nSteps\n- Toast it."}, headers=auth(ta)).json()["id"]
    assert anon.get("/v1/recipes", headers=auth(tb)).json()["items"] == []
    assert anon.get("/v1/recipes", params={"q": "tomato"}, headers=auth(tb)).json()["items"] == []
    for method, path, body in [
        ("GET", f"/v1/recipes/{rid}", None),
        ("PATCH", f"/v1/recipes/{rid}", {"version": 1, "title": "mine now"}),
        ("DELETE", f"/v1/recipes/{rid}", None),
        ("GET", f"/v1/import-drafts/{did}", None),
        ("PATCH", f"/v1/import-drafts/{did}", {"version": 1, "title": "x"}),
    ]:
        assert_error(anon.request(method, path, json=body, headers=auth(tb)), 404, "not_found")
    steal = {"draft_id": did, "title": "x", "ingredients": [{"name": "bread"}], "steps": [{"instruction": "Toast it."}]}
    assert_error(anon.post("/v1/recipes", json=steal, headers=auth(tb)), 404, "not_found")
    assert anon.get(f"/v1/recipes/{rid}", headers=auth(ta)).json()["title"] == "Tomato pasta"


def test_only_a_hash_is_stored(engine: Engine, make_user) -> None:
    token = make_token(engine, make_user())
    with engine.connect() as c:
        stored = c.execute(text("SELECT token_hash FROM api_tokens")).scalar_one()
    assert token not in stored and len(stored) == 64


def test_pairing_code_round_trips() -> None:
    code = pairing_code("https://mac.tail1234.ts.net", "ckb_abc")
    assert code.startswith(PAIRING_PREFIX)
    payload = code[len(PAIRING_PREFIX):]
    decoded = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    assert decoded == {"server": "https://mac.tail1234.ts.net", "token": "ckb_abc"}
