"""Integration tests run against a real PostgreSQL database (never SQLite).

The test database's schema is dropped and rebuilt from the Alembic migrations once per
run, and every table is truncated before each test.
"""

import os
import uuid
from collections.abc import Iterator
from pathlib import Path

import pytest
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import Engine, create_engine, text

from app.config import Settings
from app.deps import get_current_user_id
from app.main import create_app

TEST_DATABASE_URL = os.environ.get(
    "COOKBOOK_TEST_DATABASE_URL",
    "postgresql+psycopg://localhost:5432/cookbook_test",
)
BACKEND_DIR = Path(__file__).resolve().parents[1]


def alembic_config() -> Config:
    cfg = Config(str(BACKEND_DIR / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    cfg.set_main_option("sqlalchemy.url", TEST_DATABASE_URL)
    cfg.attributes["configure_logger"] = False
    return cfg


@pytest.fixture(scope="session")
def engine() -> Iterator[Engine]:
    if "test" not in TEST_DATABASE_URL.rsplit("/", 1)[-1]:
        raise RuntimeError("Refusing to wipe a database whose name doesn't contain 'test'.")
    eng = create_engine(TEST_DATABASE_URL, connect_args={"options": "-c timezone=UTC"})
    with eng.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE; CREATE SCHEMA public;"))
    command.upgrade(alembic_config(), "head")
    yield eng
    eng.dispose()


@pytest.fixture(autouse=True)
def clean_tables(engine: Engine) -> None:
    with engine.begin() as conn:
        conn.execute(text("TRUNCATE users, recipes, recipe_ingredients, recipe_steps, idempotency_keys, import_drafts, api_tokens, recipe_images CASCADE"))


def test_settings(**overrides) -> Settings:
    """Settings for tests: never read backend/.env (a developer's local S3, Anthropic or
    auth mode must not leak in), in-memory photo storage, the deterministic extractor."""
    values = dict(
        database_url=TEST_DATABASE_URL,
        auth_mode="dev",
        storage_backend="memory",
        extraction_provider="fake",
        image_signing_key="test-signing-key",
    )
    values.update(overrides)
    return Settings(_env_file=None, **values)


@pytest.fixture
def app(engine: Engine):
    return create_app(test_settings())


@pytest.fixture
def client(app) -> Iterator[TestClient]:
    with TestClient(app) as c:  # runs startup, which seeds the dev user
        yield c


@pytest.fixture
def make_user(engine: Engine):
    def _make() -> uuid.UUID:
        uid = uuid.uuid4()
        with engine.begin() as conn:
            conn.execute(text("INSERT INTO users (id) VALUES (:id)"), {"id": uid})
        return uid

    return _make


@pytest.fixture
def act_as(app):
    """Switch the identity used by subsequent requests (stands in for auth until Milestone 4)."""

    def _act_as(user_id: uuid.UUID | None) -> None:
        if user_id is None:
            app.dependency_overrides.pop(get_current_user_id, None)
        else:
            app.dependency_overrides[get_current_user_id] = lambda: user_id

    yield _act_as
    app.dependency_overrides.clear()


def count(engine: Engine, table: str) -> int:
    with engine.connect() as conn:
        return conn.execute(text(f"SELECT count(*) FROM {table}")).scalar_one()
