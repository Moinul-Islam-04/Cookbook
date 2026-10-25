"""Stage 5: a ParsedRecipe's servings and ingredient notes on the recipe tables."""

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.exc import IntegrityError

from tests.test_import_drafts import save_body, use_fake
from tests.test_recipes_api import assert_error

CAPTION = "Garlic toast. Serves 2. 2 slices bread, 3 cloves garlic, minced. Toast the bread."
OUTPUT = {
    "is_recipe": True, "title": "Garlic toast", "servings": 2,
    "ingredients": [{"raw_text": "2 slices bread", "name": "bread", "quantity": 2, "unit": "slices"},
                    {"raw_text": "3 cloves garlic, minced", "name": "garlic", "quantity": 3, "unit": "cloves", "note": "minced"}],
    "steps": [{"instruction": "Toast the bread."}],
}


def test_manual_recipe_round_trips_servings_and_notes(client: TestClient) -> None:
    res = client.post("/v1/recipes", json={
        "title": "Toast", "servings": 2,
        "ingredients": [{"name": "garlic", "quantity": 3, "unit": "clove", "note": "minced"}, {"name": "bread"}],
    })
    assert res.status_code == 201, res.text
    r = res.json()
    assert r["servings"] == 2 and [i["note"] for i in r["ingredients"]] == ["minced", None]

    patched = client.patch(f"/v1/recipes/{r['id']}", json={"version": r["version"], "servings": None})
    assert patched.status_code == 200 and patched.json()["servings"] is None
    assert patched.json()["ingredients"][0]["note"] == "minced"  # untouched


@pytest.mark.parametrize("body, field", [
    ({"title": "x", "servings": 0}, "servings"),
    ({"title": "x", "servings": 1001}, "servings"),
    ({"title": "x", "ingredients": [{"name": "a", "note": "x" * 201}]}, "ingredients.0.note"),
])
def test_out_of_range_values_are_rejected(client: TestClient, body: dict, field: str) -> None:
    res = client.post("/v1/recipes", json=body)
    assert_error(res, 422, "invalid_request")
    assert field in [e["field"] for e in res.json()["field_errors"]]


def test_saving_a_draft_keeps_its_servings_unless_the_user_changed_them(app, client: TestClient) -> None:
    use_fake(app, {CAPTION: OUTPUT})
    # The current iOS app sends neither servings nor notes.
    d = client.post("/v1/import-drafts", json={"source_text": CAPTION}).json()
    assert d["servings"] == 2
    body = save_body(d)
    assert "servings" not in body
    assert client.post("/v1/recipes", json=body).json()["servings"] == 2

    d = client.post("/v1/import-drafts", json={"source_text": CAPTION}).json()
    saved = client.post("/v1/recipes", json=save_body(d, servings=None, allow_duplicate=True)).json()
    assert saved["servings"] is None  # the user cleared it


def test_database_rejects_bad_servings_and_blank_notes(engine: Engine, make_user) -> None:
    uid = make_user()
    with pytest.raises(IntegrityError, match="ck_recipes_servings_range"), engine.begin() as conn:
        conn.execute(text("INSERT INTO recipes (user_id, title, servings) VALUES (:u, 'x', 0)"), {"u": uid})
    with engine.begin() as conn:
        rid = conn.execute(text("INSERT INTO recipes (user_id, title) VALUES (:u, 'x') RETURNING id"), {"u": uid}).scalar_one()
    with pytest.raises(IntegrityError, match="ck_recipe_ingredients_note_not_blank"), engine.begin() as conn:
        conn.execute(text(
            "INSERT INTO recipe_ingredients (recipe_id, position, name, raw_text, note) VALUES (:r, 0, 'a', 'a', ' ')"
        ), {"r": rid})
