"""python -m app.accounts link-owner: a Google sign-in takes over the owner's recipes."""

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.orm import Session

from app.accounts import LinkError, link_owner
from app.config import DEV_USER_ID
from tests.conftest import count
from tests.test_google_auth import CLIENT_ID, GOOGLE_KEY, auth, google_token, sign_in
from tests.test_recipes_api import TOMATO_PASTA


@pytest.fixture
def owner_with_recipe(client: TestClient) -> str:
    """The owner (dev mode) saves a recipe, as the Mac's database has before the move."""
    return client.post("/v1/recipes", json=TOMATO_PASTA).json()["id"]


@pytest.fixture
def anon(engine: Engine):
    from app.google_auth import GoogleVerifier
    from app.main import create_app
    from tests.conftest import test_settings as settings_for

    app = create_app(settings_for(auth_mode="token"))
    app.state.google_verifier = GoogleVerifier([CLIENT_ID], signing_key=lambda _: GOOGLE_KEY.public_key())
    with TestClient(app) as c:
        yield c


def google_user_id(engine: Engine) -> uuid.UUID:
    with engine.connect() as c:
        return c.execute(text("SELECT id FROM users WHERE auth_subject LIKE 'google:%'")).scalar_one()


def test_after_linking_google_sign_in_reaches_the_owners_recipes(owner_with_recipe, anon, engine) -> None:
    first = sign_in(anon, google_token()).json()["token"]
    assert anon.get("/v1/recipes", headers=auth(first)).json()["items"] == []  # the new, empty account

    with Session(engine) as s:
        assert link_owner(s, google_user_id(engine)) == "google:110169484474386276334"
        s.commit()

    assert anon.get("/v1/recipes", headers=auth(first)).status_code == 401  # the empty account's device is signed out
    again = sign_in(anon, google_token()).json()["token"]
    assert anon.get(f"/v1/recipes/{owner_with_recipe}", headers=auth(again)).status_code == 200
    assert count(engine, "users") == 1
    with engine.connect() as c:
        assert c.execute(text("SELECT id FROM users")).scalar_one() == DEV_USER_ID


def test_refuses_to_delete_an_account_that_has_recipes(owner_with_recipe, anon, engine) -> None:
    token = sign_in(anon, google_token()).json()["token"]
    anon.post("/v1/recipes", json=TOMATO_PASTA, headers=auth(token))
    with Session(engine) as s, pytest.raises(LinkError, match="already has recipes"):
        link_owner(s, google_user_id(engine))
    assert count(engine, "recipes") == 2


def test_refuses_when_the_owner_is_already_linked(owner_with_recipe, anon, engine) -> None:
    sign_in(anon, google_token(sub="first"))
    with Session(engine) as s:
        link_owner(s, google_user_id(engine))
        s.commit()
    sign_in(anon, google_token(sub="second"))
    with engine.connect() as c:
        second = c.execute(text("SELECT id FROM users WHERE auth_subject = 'google:second'")).scalar_one()
    with Session(engine) as s, pytest.raises(LinkError, match="already linked"):
        link_owner(s, second)


@pytest.mark.parametrize("target", ["owner", "unknown"])
def test_refuses_bad_targets(owner_with_recipe, engine, target) -> None:
    uid = DEV_USER_ID if target == "owner" else uuid.uuid4()
    with Session(engine) as s, pytest.raises(LinkError):
        link_owner(s, uid)
