"""Migration and database-level constraint checks, independent of the API layer."""

import uuid

import pytest
from alembic import command
from sqlalchemy import Engine, text
from sqlalchemy.exc import IntegrityError

from tests.conftest import alembic_config, count


def test_migrations_round_trip_and_match_models(engine: Engine) -> None:
    cfg = alembic_config()
    command.downgrade(cfg, "base")
    with engine.connect() as conn:
        tables = conn.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename <> 'alembic_version'")
        ).scalars().all()
    assert tables == []
    command.upgrade(cfg, "head")
    command.check(cfg)  # raises if app/models.py and the migrations disagree


@pytest.fixture
def recipe_id(engine: Engine) -> uuid.UUID:
    uid, rid = uuid.uuid4(), uuid.uuid4()
    with engine.begin() as conn:
        conn.execute(text("INSERT INTO users (id) VALUES (:u)"), {"u": uid})
        conn.execute(
            text("INSERT INTO recipes (id, user_id, title) VALUES (:r, :u, 'Soup')"),
            {"r": rid, "u": uid},
        )
    return rid


def _insert_ingredient(engine: Engine, recipe_id, position=0, name="salt", quantity=None, raw="salt"):
    with engine.begin() as conn:
        conn.execute(
            text(
                "INSERT INTO recipe_ingredients (recipe_id, position, name, quantity, raw_text) "
                "VALUES (:r, :p, :n, :q, :raw)"
            ),
            {"r": recipe_id, "p": position, "n": name, "q": quantity, "raw": raw},
        )


def test_child_requires_existing_parent(engine: Engine) -> None:
    with pytest.raises(IntegrityError, match="fk_recipe_ingredients_recipe_id_recipes"):
        _insert_ingredient(engine, uuid.uuid4())


def test_recipe_requires_existing_user(engine: Engine) -> None:
    with pytest.raises(IntegrityError, match="fk_recipes_user_id_users"), engine.begin() as conn:
        conn.execute(text("INSERT INTO recipes (user_id, title) VALUES (:u, 'x')"), {"u": uuid.uuid4()})


def test_positions_are_unique_per_recipe(engine: Engine, recipe_id) -> None:
    _insert_ingredient(engine, recipe_id, position=0)
    with pytest.raises(IntegrityError, match="uq_recipe_ingredients_recipe_id_position"):
        _insert_ingredient(engine, recipe_id, position=0, name="pepper", raw="pepper")


@pytest.mark.parametrize(
    "kwargs, constraint",
    [
        ({"position": -1}, "position_nonnegative"),
        ({"name": "   "}, "name_not_blank"),
        ({"quantity": -2}, "quantity_positive"),
        ({"quantity": 0}, "quantity_positive"),
        ({"raw": " "}, "raw_text_not_blank"),
    ],
)
def test_ingredient_checks(engine: Engine, recipe_id, kwargs, constraint) -> None:
    with pytest.raises(IntegrityError, match=constraint):
        _insert_ingredient(engine, recipe_id, **kwargs)


def test_blank_title_rejected(engine: Engine, recipe_id) -> None:
    with pytest.raises(IntegrityError, match="title_not_blank"), engine.begin() as conn:
        conn.execute(text("UPDATE recipes SET title = '  ' WHERE id = :r"), {"r": recipe_id})


def test_deleting_recipe_cascades_to_children(engine: Engine, recipe_id) -> None:
    _insert_ingredient(engine, recipe_id)
    with engine.begin() as conn:
        conn.execute(
            text("INSERT INTO recipe_steps (recipe_id, position, instruction) VALUES (:r, 0, 'Stir')"),
            {"r": recipe_id},
        )
        conn.execute(text("DELETE FROM recipes WHERE id = :r"), {"r": recipe_id})
    assert count(engine, "recipe_ingredients") == 0
    assert count(engine, "recipe_steps") == 0
