"""The model's original output is kept (never patched, never returned) so corrections can
be measured after drafts are cleaned up."""

import json

from fastapi.testclient import TestClient
from sqlalchemy import Engine, text
from sqlalchemy.orm import Session

from app.cleanup import cleanup
from app.corrections import report
from app.extraction.validate import validate_extraction
from tests.test_import_drafts import BRIEF_CAPTION, BRIEF_OUTPUT, make_draft, save_body, use_fake

POST_URL = "https://www.instagram.com/p/ABC123/"


def model_output() -> dict:
    """What create_draft stores: the validated provider output, as JSON."""
    return validate_extraction(json.dumps(BRIEF_OUTPUT), BRIEF_CAPTION).model_dump(mode="json")


def draft_row(engine: Engine, draft_id: str):
    with engine.connect() as conn:
        return conn.execute(
            text("SELECT content, extracted_content, extraction_version FROM import_drafts WHERE id = :id"),
            {"id": draft_id},
        ).one()


def recipe_row(engine: Engine, recipe_id: str):
    with engine.connect() as conn:
        return conn.execute(
            text("SELECT extracted_content, extraction_version FROM recipes WHERE id = :id"),
            {"id": recipe_id},
        ).one()


def test_original_output_survives_draft_patch(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    d = make_draft(client, BRIEF_CAPTION)
    assert draft_row(engine, d["id"]).extracted_content == model_output()

    res = client.patch(f"/v1/import-drafts/{d['id']}", json={
        "version": 1,
        "title": "Weeknight tomato pasta",
        "ingredients": [{"raw_text": "200g pasta", "name": "pasta", "quantity": 200, "unit": "g"}],
        "steps": [{"instruction": "Boil the pasta"}],
    })
    assert res.status_code == 200, res.text
    row = draft_row(engine, d["id"])
    assert row.content["title"] == "Weeknight tomato pasta"
    assert row.extracted_content == model_output()


def test_duplicate_warning_is_not_part_of_the_model_output(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    first = make_draft(client, BRIEF_CAPTION, source_url=POST_URL)
    assert client.post("/v1/recipes", json=save_body(first)).status_code == 201
    second = make_draft(client, BRIEF_CAPTION, source_url=POST_URL)
    assert second["warnings"][0]["code"] == "duplicate_post"
    assert draft_row(engine, second["id"]).extracted_content == model_output()


def test_saving_copies_output_to_recipe_and_it_outlives_cleanup(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    d = make_draft(client, BRIEF_CAPTION)
    res = client.post("/v1/recipes", json=save_body(d, title="My pasta"))
    assert res.status_code == 201, res.text
    recipe_id = res.json()["id"]
    row = recipe_row(engine, recipe_id)
    assert row.extracted_content == model_output()
    assert row.extraction_version == d["extraction_version"]

    with engine.begin() as conn:
        conn.execute(text("UPDATE import_drafts SET expires_at = now() - interval '1 second'"))
    with Session(engine) as s:
        assert cleanup(s)["import_drafts"] == 1
    row = recipe_row(engine, recipe_id)
    assert row.extracted_content == model_output()
    assert row.extraction_version == d["extraction_version"]

    # Editing the recipe leaves the model's output alone.
    patch = client.patch(f"/v1/recipes/{recipe_id}", json={"version": 1, "title": "Renamed"})
    assert patch.status_code == 200, patch.text
    assert recipe_row(engine, recipe_id).extracted_content == model_output()


def test_manual_recipes_have_nulls(client: TestClient, engine: Engine) -> None:
    res = client.post("/v1/recipes", json={"title": "Toast", "ingredients": [{"name": "bread", "raw_text": "bread"}]})
    assert res.status_code == 201, res.text
    with engine.connect() as conn:  # SQL NULL, not a JSON null
        row = conn.execute(
            text("SELECT extracted_content IS NULL AS no_output, extraction_version IS NULL AS no_version FROM recipes WHERE id = :id"),
            {"id": res.json()["id"]},
        ).one()
    assert row.no_output and row.no_version


def test_responses_never_include_the_original_output(app, client: TestClient) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    d = make_draft(client, BRIEF_CAPTION)
    saved = client.post("/v1/recipes", json=save_body(d)).json()
    bodies = [
        d,
        client.get(f"/v1/import-drafts/{d['id']}").json(),
        saved,
        client.get(f"/v1/recipes/{saved['id']}").json(),
        client.get("/v1/recipes").json(),
    ]
    for body in bodies:
        assert "extracted_content" not in str(body)
    assert "extracted_content" not in str(app.openapi())


def test_corrections_report(app, client: TestClient, engine: Engine) -> None:
    use_fake(app, {BRIEF_CAPTION: BRIEF_OUTPUT})
    d = make_draft(client, BRIEF_CAPTION)
    # Model: pasta, 2 tomatoes, olive oil / Cook pasta, toss with tomatoes and oil.
    body = save_body(d)
    body["ingredients"] = [
        {"raw_text": "pasta", "name": "pasta", "quantity": 200, "unit": "g"},  # quantity changed
        {"raw_text": "2 tomatoes", "name": "tomatoes", "quantity": 2},  # unchanged
        {"raw_text": "salt", "name": "salt"},  # olive oil replaced: edited
        {"raw_text": "basil", "name": "basil"},  # added
    ]
    body["steps"] = [{"instruction": "Cook pasta"}]  # second step removed
    assert client.post("/v1/recipes", json=body).status_code == 201
    # A manual recipe isn't counted.
    client.post("/v1/recipes", json={"title": "Toast"})

    with Session(engine) as s:
        totals = report(s)
    assert list(totals) == [d["extraction_version"]]
    c = totals[d["extraction_version"]]
    assert (c.recipes, c.ingredients_extracted, c.steps_extracted) == (1, 3, 2)
    assert (c.ingredients_added, c.ingredients_removed, c.ingredients_edited) == (1, 0, 2)
    assert c.quantities_changed == 1
    assert (c.steps_added, c.steps_removed, c.steps_edited) == (0, 1, 0)


def test_corrections_report_is_empty_without_imports(engine: Engine) -> None:
    with Session(engine) as s:
        assert report(s) == {}
