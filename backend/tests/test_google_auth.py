"""POST /v1/auth/google: Google ID tokens are verified, then exchanged for a device token.

A locally generated RSA key stands in for Google's signing key; a second key signs forged
tokens. Nothing here contacts Google.
"""

import time

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text

from app.google_auth import GoogleUnavailable, GoogleVerifier
from app.main import create_app
from tests.conftest import count
from tests.conftest import test_settings as settings_for
from tests.test_recipes_api import TOMATO_PASTA, assert_error

CLIENT_ID = "1234-ios.apps.googleusercontent.com"
GOOGLE_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
FORGER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def google_token(key=GOOGLE_KEY, **overrides) -> str:
    now = int(time.time())
    claims = {
        "iss": "https://accounts.google.com",
        "aud": CLIENT_ID,
        "sub": "110169484474386276334",
        "iat": now,
        "exp": now + 3600,
        "email": "cook@example.com",
    }
    claims.update(overrides)
    claims = {k: v for k, v in claims.items() if v is not None}
    return jwt.encode(claims, key, algorithm="RS256", headers={"kid": "test"})


@pytest.fixture
def token_app(engine: Engine):
    app = create_app(settings_for(auth_mode="token"))
    app.state.google_verifier = GoogleVerifier([CLIENT_ID], signing_key=lambda _: GOOGLE_KEY.public_key())
    return app


@pytest.fixture
def anon(token_app):
    with TestClient(token_app) as c:
        yield c


def sign_in(anon: TestClient, id_token: str, device: str = "iPhone"):
    return anon.post("/v1/auth/google", json={"id_token": id_token, "device_name": device})


def auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_sign_in_returns_a_device_token_that_works(anon: TestClient, engine: Engine) -> None:
    res = sign_in(anon, google_token())
    assert res.status_code == 201, res.text
    body = res.json()
    assert body["token"].startswith("ckb_") and set(body) == {"token", "token_id", "expires_at"}
    assert anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(body["token"])).status_code == 201
    with engine.connect() as c:
        subject = c.execute(text("SELECT auth_subject FROM users WHERE auth_subject IS NOT NULL")).scalar_one()
    assert subject == "google:110169484474386276334"


def test_signing_in_again_reaches_the_same_recipes(anon: TestClient, engine: Engine) -> None:
    first = sign_in(anon, google_token(), "iPhone").json()["token"]
    rid = anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(first)).json()["id"]
    second = sign_in(anon, google_token(), "iPad").json()["token"]
    assert second != first
    assert anon.get(f"/v1/recipes/{rid}", headers=auth(second)).status_code == 200
    assert count(engine, "users WHERE auth_subject IS NOT NULL") == 1
    assert count(engine, "api_tokens") == 2


def test_two_google_users_cannot_see_each_others_recipes(anon: TestClient) -> None:
    a = sign_in(anon, google_token(sub="user-a")).json()["token"]
    b = sign_in(anon, google_token(sub="user-b")).json()["token"]
    rid = anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(a)).json()["id"]
    assert anon.get("/v1/recipes", headers=auth(b)).json()["items"] == []
    assert_error(anon.get(f"/v1/recipes/{rid}", headers=auth(b)), 404, "not_found")


@pytest.mark.parametrize(
    "id_token",
    [
        pytest.param(google_token(key=FORGER_KEY), id="forged-signature"),
        pytest.param(google_token(aud="someone-elses-app.apps.googleusercontent.com"), id="wrong-audience"),
        pytest.param(google_token(iss="https://evil.example.com"), id="wrong-issuer"),
        pytest.param(google_token(exp=int(time.time()) - 120, iat=int(time.time()) - 3720), id="expired"),
        pytest.param(google_token(sub=None), id="no-subject"),
        pytest.param(google_token(sub=""), id="empty-subject"),
        pytest.param("not.a.jwt", id="garbage"),
    ],
)
def test_bad_google_tokens_are_rejected(anon: TestClient, engine: Engine, id_token: str) -> None:
    body = assert_error(sign_in(anon, id_token), 401, "unauthenticated")
    assert "Google sign-in couldn't be verified" in body["message"]
    assert count(engine, "users WHERE auth_subject IS NOT NULL") == 0
    assert count(engine, "api_tokens") == 0


def test_the_older_issuer_spelling_is_accepted(anon: TestClient) -> None:
    assert sign_in(anon, google_token(iss="accounts.google.com")).status_code == 201


def test_google_outage_is_retryable(token_app, anon: TestClient) -> None:
    def unreachable(_):
        raise GoogleUnavailable()

    token_app.state.google_verifier._signing_key = unreachable
    body = assert_error(sign_in(anon, google_token()), 503, "auth_unavailable")
    assert body["retryable"] is True


def test_turned_off_without_client_ids(engine: Engine) -> None:
    with TestClient(create_app(settings_for(auth_mode="token"))) as c:
        assert_error(sign_in(c, google_token()), 404, "not_found")


def test_device_name_is_required(anon: TestClient) -> None:
    res = anon.post("/v1/auth/google", json={"id_token": google_token()})
    assert_error(res, 422, "invalid_request")
