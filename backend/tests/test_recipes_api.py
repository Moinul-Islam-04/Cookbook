import threading
import uuid
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine

from app.config import Settings
from app.main import create_app
from app.models import RecipeIngredient
from app.routers import recipes as recipes_router
from tests.conftest import TEST_DATABASE_URL, count

TOMATO_PASTA = {
    "title": "Tomato pasta",
    "ingredients": [
        {"name": "pasta"},
        {"name": "tomatoes", "quantity": 2},
        {"name": "olive oil"},
        {"name": "salt", "raw_text": "salt to taste"},
        {"name": "flour", "quantity": 1.5, "unit": "cups"},
    ],
    "steps": [{"instruction": "Cook pasta."}, {"instruction": "Toss with tomatoes and oil."}],
}


def create(client: TestClient, body=None) -> dict:
    res = client.post("/v1/recipes", json=body or TOMATO_PASTA)
    assert res.status_code == 201, res.text
    return res.json()


def assert_error(res, status: int, code: str) -> dict:
    assert res.status_code == status, res.text
    body = res.json()
    assert body["code"] == code
    assert set(body) >= {"code", "message", "field_errors", "retryable", "request_id"}
    return body


# ---------- create ----------


def test_create_returns_full_recipe_and_location(client: TestClient) -> None:
    res = client.post("/v1/recipes", json=TOMATO_PASTA)
    assert res.status_code == 201
    body = res.json()
    assert res.headers["location"] == f"/v1/recipes/{body['id']}"
    assert body["version"] == 1 and body["source_kind"] == "manual" and body["missing"] == []
    assert body["created_at"].endswith("Z") or body["created_at"].endswith("+00:00")

    ings = body["ingredients"]
    assert [i["position"] for i in ings] == [0, 1, 2, 3, 4]
    # Missing measurements stay missing; nothing is invented.
    assert ings[0] == {**ings[0], "name": "pasta", "quantity": None, "unit": None, "raw_text": "pasta"}
    assert ings[1]["quantity"] == 2 and ings[1]["unit"] is None and ings[1]["raw_text"] == "2 tomatoes"
    assert ings[3]["quantity"] is None and ings[3]["raw_text"] == "salt to taste"
    assert ings[4]["quantity"] == 1.5 and ings[4]["raw_text"] == "1.5 cups flour"
    assert [s["instruction"] for s in body["steps"]] == ["Cook pasta.", "Toss with tomatoes and oil."]


def test_whitespace_is_trimmed_and_blank_optionals_become_null(client: TestClient) -> None:
    body = create(
        client,
        {"title": "  Soup  ", "notes": "   ", "ingredients": [{"name": " leeks ", "unit": " "}]},
    )
    assert body["title"] == "Soup" and body["notes"] is None
    assert body["ingredients"][0]["name"] == "leeks" and body["ingredients"][0]["unit"] is None


def test_incomplete_recipe_is_saved_and_flagged(client: TestClient) -> None:
    body = create(client, {"title": "Grandma's stew"})
    assert body["ingredients"] == [] and body["steps"] == []
    assert body["missing"] == ["ingredients", "steps"]


@pytest.mark.parametrize(
    "body, field",
    [
        ({"title": "   "}, "title"),
        ({}, "title"),
        ({"title": "x" * 201}, "title"),
        ({"title": "ok", "user_id": str(uuid.uuid4())}, "user_id"),
        ({"title": "ok", "ingredients": [{"name": ""}]}, "ingredients.0.name"),
        ({"title": "ok", "ingredients": [{"name": "salt", "quantity": -1}]}, "ingredients.0.quantity"),
        ({"title": "ok", "ingredients": [{"name": "salt", "quantity": 0}]}, "ingredients.0.quantity"),
        ({"title": "ok", "ingredients": [{"name": "salt", "quantity": 0.3333}]}, "ingredients.0.quantity"),
        ({"title": "ok", "steps": [{"instruction": "  "}]}, "steps.0.instruction"),
        ({"title": "ok", "ingredients": [{"name": "a"}] * 201}, "ingredients"),
    ],
)
def test_invalid_create_saves_nothing(client: TestClient, engine: Engine, body, field) -> None:
    res = client.post("/v1/recipes", json=body)
    err = assert_error(res, 422, "invalid_request")
    assert field in [e["field"] for e in err["field_errors"]]
    assert count(engine, "recipes") == 0 and count(engine, "recipe_ingredients") == 0


def test_database_failure_mid_save_rolls_back_everything(
    client: TestClient, engine: Engine, monkeypatch
) -> None:
    # Simulate a child row that slips past request validation but fails a DB constraint
    # after the parent recipe row has been staged in the same transaction.
    def bad_rows(items):
        return [RecipeIngredient(position=0, name="x", quantity=Decimal("-1"), raw_text="x")]

    monkeypatch.setattr(recipes_router, "_ingredient_rows", bad_rows)
    res = client.post("/v1/recipes", json=TOMATO_PASTA)
    err = assert_error(res, 422, "constraint_violation")
    assert err["details"]["constraint"] == "ck_recipe_ingredients_quantity_positive"
    assert count(engine, "recipes") == 0
    assert count(engine, "recipe_ingredients") == 0
    assert count(engine, "recipe_steps") == 0


# ---------- read ----------


def test_get_returns_saved_recipe(client: TestClient) -> None:
    created = create(client)
    res = client.get(f"/v1/recipes/{created['id']}")
    assert res.status_code == 200 and res.json() == created


def test_unknown_and_malformed_ids(client: TestClient) -> None:
    assert_error(client.get(f"/v1/recipes/{uuid.uuid4()}"), 404, "not_found")
    assert_error(client.get("/v1/recipes/not-a-uuid"), 422, "invalid_request")


def test_request_id_is_echoed(client: TestClient) -> None:
    res = client.get(f"/v1/recipes/{uuid.uuid4()}", headers={"X-Request-ID": "abc-123"})
    assert res.headers["x-request-id"] == "abc-123" and res.json()["request_id"] == "abc-123"


# ---------- list / pagination ----------


def test_empty_list(client: TestClient) -> None:
    assert client.get("/v1/recipes").json() == {"items": [], "next_cursor": None}


def test_pagination_is_stable_and_complete(client: TestClient) -> None:
    ids = [create(client, {"title": f"Recipe {i}"})["id"] for i in range(25)]
    seen, cursor, pages = [], None, 0
    while True:
        params = {"limit": 10} | ({"cursor": cursor} if cursor else {})
        page = client.get("/v1/recipes", params=params).json()
        seen += [r["id"] for r in page["items"]]
        pages += 1
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert pages == 3
    assert seen == list(reversed(ids))  # newest first, no duplicates, nothing skipped


def test_list_summary_fields(client: TestClient) -> None:
    create(client)
    create(client, {"title": "Bare"})
    items = client.get("/v1/recipes").json()["items"]
    assert [(i["title"], i["ingredient_count"], i["step_count"], i["missing"]) for i in items] == [
        ("Bare", 0, 0, ["ingredients", "steps"]),
        ("Tomato pasta", 5, 2, []),
    ]


@pytest.mark.parametrize("params", [{"limit": 0}, {"limit": 101}, {"cursor": "garbage!"}])
def test_bad_list_params(client: TestClient, params) -> None:
    assert_error(client.get("/v1/recipes", params=params), 422, "invalid_request")


# ---------- update ----------


def test_patch_title_leaves_children_untouched(client: TestClient) -> None:
    created = create(client)
    res = client.patch(f"/v1/recipes/{created['id']}", json={"version": 1, "title": "Quick pasta"})
    body = res.json()
    assert res.status_code == 200
    assert body["title"] == "Quick pasta" and body["version"] == 2
    assert body["ingredients"] == created["ingredients"] and body["steps"] == created["steps"]
    assert body["updated_at"] > created["updated_at"]


def test_patch_replaces_and_reorders_children(client: TestClient, engine: Engine) -> None:
    created = create(client)
    new_ings = [{"name": "olive oil"}, {"name": "pasta", "quantity": 200, "unit": "g"}]
    res = client.patch(
        f"/v1/recipes/{created['id']}",
        json={"version": 1, "ingredients": new_ings, "steps": [{"instruction": "Boil."}]},
    )
    body = res.json()
    assert res.status_code == 200, res.text
    assert [(i["position"], i["name"], i["raw_text"]) for i in body["ingredients"]] == [
        (0, "olive oil", "olive oil"),
        (1, "pasta", "200 g pasta"),
    ]
    assert [s["instruction"] for s in body["steps"]] == ["Boil."]
    assert count(engine, "recipe_ingredients") == 2 and count(engine, "recipe_steps") == 1
    assert client.get(f"/v1/recipes/{created['id']}").json() == body


def test_patch_can_clear_children_and_notes(client: TestClient) -> None:
    created = create(client, {**TOMATO_PASTA, "notes": "Family favorite"})
    body = client.patch(
        f"/v1/recipes/{created['id']}", json={"version": 1, "steps": [], "notes": None}
    ).json()
    assert body["steps"] == [] and body["notes"] is None and body["missing"] == ["steps"]


def test_stale_version_is_rejected_and_nothing_changes(client: TestClient) -> None:
    created = create(client)
    rid = created["id"]
    assert client.patch(f"/v1/recipes/{rid}", json={"version": 1, "title": "A"}).status_code == 200
    err = assert_error(
        client.patch(f"/v1/recipes/{rid}", json={"version": 1, "title": "B", "steps": []}),
        409,
        "stale_version",
    )
    assert err["details"] == {"current_version": 2}
    current = client.get(f"/v1/recipes/{rid}").json()
    assert current["title"] == "A" and current["steps"] == created["steps"]


@pytest.mark.parametrize(
    "patch, field",
    [
        ({"title": None}, "body"),
        ({"ingredients": None}, "body"),
        ({}, "version"),
        ({"ingredients": [{"name": "ok"}, {"name": "salt", "quantity": -1}]}, "ingredients.1.quantity"),
    ],
)
def test_invalid_patch_changes_nothing(client: TestClient, patch, field) -> None:
    created = create(client)
    body = {"version": 1} | patch if field != "version" else {"title": "x"}
    err = assert_error(client.patch(f"/v1/recipes/{created['id']}", json=body), 422, "invalid_request")
    assert field in [e["field"] for e in err["field_errors"]]
    assert client.get(f"/v1/recipes/{created['id']}").json() == created


def test_failed_child_replacement_rolls_back(client: TestClient, monkeypatch) -> None:
    created = create(client)

    def bad_rows(items):
        return [RecipeIngredient(position=0, name="x", quantity=Decimal("-1"), raw_text="x")]

    monkeypatch.setattr(recipes_router, "_ingredient_rows", bad_rows)
    res = client.patch(
        f"/v1/recipes/{created['id']}",
        json={"version": 1, "title": "Changed", "ingredients": [{"name": "x"}]},
    )
    assert_error(res, 422, "constraint_violation")
    assert client.get(f"/v1/recipes/{created['id']}").json() == created


def test_concurrent_edits_with_same_version_one_wins(app) -> None:
    with TestClient(app) as c:
        rid = create(c)["id"]
    results: list[int] = []
    barrier = threading.Barrier(2)

    def edit(title: str) -> None:
        with TestClient(app) as c:
            barrier.wait()
            results.append(c.patch(f"/v1/recipes/{rid}", json={"version": 1, "title": title}).status_code)

    threads = [threading.Thread(target=edit, args=(t,)) for t in ("A", "B")]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [200, 409]
    with TestClient(app) as c:
        assert c.get(f"/v1/recipes/{rid}").json()["version"] == 2


# ---------- delete ----------


def test_delete_removes_recipe_and_children(client: TestClient, engine: Engine) -> None:
    created = create(client)
    res = client.delete(f"/v1/recipes/{created['id']}")
    assert res.status_code == 204 and res.content == b""
    assert_error(client.get(f"/v1/recipes/{created['id']}"), 404, "not_found")
    assert_error(client.delete(f"/v1/recipes/{created['id']}"), 404, "not_found")
    assert count(engine, "recipe_ingredients") == 0 and count(engine, "recipe_steps") == 0


# ---------- ownership (dev identity override until real auth) ----------


def test_other_user_cannot_see_or_change_recipes(client: TestClient, make_user, act_as) -> None:
    mine = create(client)
    act_as(make_user())
    rid = mine["id"]
    assert client.get("/v1/recipes").json()["items"] == []
    assert_error(client.get(f"/v1/recipes/{rid}"), 404, "not_found")
    assert_error(client.patch(f"/v1/recipes/{rid}", json={"version": 1, "title": "x"}), 404, "not_found")
    assert_error(client.delete(f"/v1/recipes/{rid}"), 404, "not_found")
    act_as(None)
    assert client.get(f"/v1/recipes/{rid}").json() == mine


# ---------- persistence ----------


def test_saved_data_survives_server_restart(engine: Engine) -> None:
    settings = Settings(database_url=TEST_DATABASE_URL, auth_mode="dev")
    with TestClient(create_app(settings)) as first:
        created = create(first)
    # A brand-new app instance with a fresh connection pool reads the same data.
    with TestClient(create_app(settings)) as second:
        assert second.get(f"/v1/recipes/{created['id']}").json() == created


def test_unknown_auth_mode_refuses_to_start() -> None:
    with pytest.raises(RuntimeError, match="Unknown COOKBOOK_AUTH_MODE"):
        create_app(Settings(database_url=TEST_DATABASE_URL, auth_mode="jwt"))
