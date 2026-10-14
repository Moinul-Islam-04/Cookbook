import threading
import uuid

from fastapi.testclient import TestClient
from sqlalchemy import Engine

from tests.conftest import count
from tests.test_recipes_api import assert_error, create

REEL = "https://www.instagram.com/reel/C1a2B3c4D5e/?igsh=abc"
SAME_POST = "instagram.com/p/C1a2B3c4D5e"


def recipe(title: str, *ingredients: str, **extra) -> dict:
    return {"title": title, "ingredients": [{"name": n} for n in ingredients], **extra}


# ---------- search ----------


def search(client: TestClient, q: str, **params) -> dict:
    res = client.get("/v1/recipes", params={"q": q, **params})
    assert res.status_code == 200, res.text
    return res.json()


def test_search_matches_title_or_ingredient_case_insensitively(client: TestClient) -> None:
    pasta = create(client, recipe("Garlic Pasta", "spaghetti", "garlic"))
    soup = create(client, recipe("Tomato soup", "tomatoes", "GARLIC cloves"))
    create(client, recipe("Overnight oats", "oats", "milk"))
    assert {r["id"] for r in search(client, "garlic")["items"]} == {pasta["id"], soup["id"]}
    assert [r["id"] for r in search(client, "SPAGH")["items"]] == [pasta["id"]]
    assert [r["id"] for r in search(client, "  soup ")["items"]] == [soup["id"]]
    assert search(client, "chocolate")["items"] == []


def test_recipe_matching_title_and_several_ingredients_is_returned_once(client: TestClient) -> None:
    created = create(client, recipe("Garlic bread", "garlic", "garlic butter", "roasted garlic"))
    items = search(client, "garlic")["items"]
    assert [r["id"] for r in items] == [created["id"]]


def test_like_wildcards_in_query_are_literal(client: TestClient) -> None:
    create(client, recipe("100% rye bread", "rye"))
    create(client, recipe("Plain bread", "flour"))
    assert [r["title"] for r in search(client, "100%")["items"]] == ["100% rye bread"]
    assert search(client, "_")["items"] == []
    assert search(client, "%")["items"] == [search(client, "100%")["items"][0]]


def test_blank_query_lists_everything(client: TestClient) -> None:
    create(client, recipe("A"))
    create(client, recipe("B"))
    assert len(search(client, "   ")["items"]) == 2


def test_search_pagination_is_complete_and_cursor_is_bound_to_query(client: TestClient) -> None:
    for i in range(7):
        create(client, recipe(f"Chicken {i}", "chicken"))
        create(client, recipe(f"Beef {i}", "beef"))
    seen, cursor = [], None
    while True:
        page = search(client, "chicken", limit=3, **({"cursor": cursor} if cursor else {}))
        seen += [r["title"] for r in page["items"]]
        cursor = page["next_cursor"]
        if not cursor:
            break
    assert seen == [f"Chicken {i}" for i in reversed(range(7))]

    first = search(client, "chicken", limit=3)
    res = client.get("/v1/recipes", params={"q": "beef", "cursor": first["next_cursor"]})
    body = assert_error(res, 422, "invalid_request")
    assert body["field_errors"][0]["field"] == "cursor"
    # And a cursor from the unfiltered list can't continue a search.
    unfiltered = client.get("/v1/recipes", params={"limit": 3}).json()
    assert_error(
        client.get("/v1/recipes", params={"q": "beef", "cursor": unfiltered["next_cursor"]}),
        422,
        "invalid_request",
    )


def test_search_is_scoped_to_owner(client: TestClient, make_user, act_as) -> None:
    create(client, recipe("Secret garlic sauce", "garlic"))
    act_as(make_user())
    assert search(client, "garlic")["items"] == []


def test_query_too_long_rejected(client: TestClient) -> None:
    assert_error(client.get("/v1/recipes", params={"q": "x" * 201}), 422, "invalid_request")


# ---------- source links and duplicate warnings ----------


def test_source_url_is_normalized_and_returned(client: TestClient) -> None:
    created = create(client, recipe("Reel pasta", source_url=REEL))
    assert created["source_url"] == "https://www.instagram.com/reel/C1a2B3c4D5e/"
    listed = client.get("/v1/recipes").json()["items"][0]
    assert listed["source_url"] == created["source_url"]


def test_unsupported_source_url_rejected_and_nothing_saved(client: TestClient, engine: Engine) -> None:
    res = client.post("/v1/recipes", json=recipe("x", source_url="https://www.tiktok.com/@a/video/1"))
    body = assert_error(res, 422, "invalid_request")
    assert body["field_errors"][0]["field"] == "source_url"
    assert count(engine, "recipes") == 0


def test_same_post_warns_with_existing_recipe(client: TestClient, engine: Engine) -> None:
    first = create(client, recipe("Reel pasta", source_url=REEL))
    res = client.post("/v1/recipes", json=recipe("Same reel again", source_url=SAME_POST))
    body = assert_error(res, 409, "duplicate_recipe")
    assert body["details"] == {"existing_recipe_id": first["id"], "existing_title": "Reel pasta"}
    assert count(engine, "recipes") == 1


def test_allow_duplicate_saves_a_deliberate_copy(client: TestClient) -> None:
    create(client, recipe("Reel pasta", source_url=REEL))
    copy = create(client, recipe("Reel pasta (vegan)", source_url=SAME_POST, allow_duplicate=True))
    assert copy["source_url"] == "https://www.instagram.com/p/C1a2B3c4D5e/"
    assert len(client.get("/v1/recipes").json()["items"]) == 2


def test_other_users_post_is_not_a_duplicate(client: TestClient, make_user, act_as) -> None:
    create(client, recipe("Mine", source_url=REEL))
    act_as(make_user())
    create(client, recipe("Theirs", source_url=REEL))


def test_recipes_without_links_never_conflict(client: TestClient) -> None:
    create(client, recipe("Same"))
    create(client, recipe("Same"))


def test_patch_source_url_warns_on_duplicate_and_can_clear(client: TestClient) -> None:
    first = create(client, recipe("Reel pasta", source_url=REEL))
    other = create(client, recipe("Something else"))
    res = client.patch(f"/v1/recipes/{other['id']}", json={"version": 1, "source_url": SAME_POST})
    assert assert_error(res, 409, "duplicate_recipe")["details"]["existing_recipe_id"] == first["id"]
    assert client.get(f"/v1/recipes/{other['id']}").json()["version"] == 1  # nothing changed

    # Re-saving a recipe's own link isn't a duplicate of itself.
    res = client.patch(f"/v1/recipes/{first['id']}", json={"version": 1, "source_url": SAME_POST})
    assert res.status_code == 200, res.text
    res = client.patch(f"/v1/recipes/{first['id']}", json={"version": 2, "source_url": None})
    assert res.status_code == 200 and res.json()["source_url"] is None
    # Now the post is free again.
    res = client.patch(f"/v1/recipes/{other['id']}", json={"version": 1, "source_url": REEL})
    assert res.status_code == 200, res.text


def test_simultaneous_saves_of_same_post_warn_exactly_once(app) -> None:
    results: list[int] = []
    barrier = threading.Barrier(4)

    def save(i: int) -> None:
        with TestClient(app) as c:
            barrier.wait()
            results.append(c.post("/v1/recipes", json=recipe(f"Copy {i}", source_url=REEL)).status_code)

    threads = [threading.Thread(target=save, args=(i,)) for i in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(results) == [201, 409, 409, 409]


# ---------- idempotency ----------


def post_with_key(client: TestClient, body: dict, key: str):
    return client.post("/v1/recipes", json=body, headers={"Idempotency-Key": key})


def test_retry_with_same_key_returns_original_and_saves_once(client: TestClient, engine: Engine) -> None:
    key = str(uuid.uuid4())
    first = post_with_key(client, recipe("Soup", "water"), key)
    assert first.status_code == 201
    retry = post_with_key(client, recipe("Soup", "water"), key)
    assert retry.status_code == 201
    assert retry.json() == first.json()
    assert retry.headers["Location"] == first.headers["Location"]
    assert retry.headers["Idempotent-Replayed"] == "true"
    assert count(engine, "recipes") == 1


def test_same_key_with_different_body_conflicts(client: TestClient, engine: Engine) -> None:
    key = str(uuid.uuid4())
    post_with_key(client, recipe("Soup"), key)
    assert_error(post_with_key(client, recipe("Different soup"), key), 409, "idempotency_key_reused")
    assert count(engine, "recipes") == 1


def test_retry_of_a_duplicate_allowed_save_does_not_trip_the_duplicate_check(client: TestClient) -> None:
    create(client, recipe("Original", source_url=REEL))
    body = recipe("Copy", source_url=REEL, allow_duplicate=True)
    key = str(uuid.uuid4())
    assert post_with_key(client, body, key).status_code == 201
    assert post_with_key(client, body, key).status_code == 201
    assert len(client.get("/v1/recipes").json()["items"]) == 2


def test_failed_request_does_not_consume_key(client: TestClient) -> None:
    create(client, recipe("Original", source_url=REEL))
    key = str(uuid.uuid4())
    assert_error(post_with_key(client, recipe("Dup", source_url=REEL), key), 409, "duplicate_recipe")
    # The user then chooses "Save Anyway" with the same key: a different body, but the key was never stored.
    res = post_with_key(client, recipe("Dup", source_url=REEL, allow_duplicate=True), key)
    assert res.status_code == 201, res.text


def test_keys_are_per_user(client: TestClient, make_user, act_as) -> None:
    key = "shared-key"
    mine = post_with_key(client, recipe("Mine"), key).json()
    act_as(make_user())
    theirs = post_with_key(client, recipe("Theirs"), key)
    assert theirs.status_code == 201 and theirs.json()["id"] != mine["id"]


def test_replay_survives_recipe_deletion(client: TestClient) -> None:
    key = str(uuid.uuid4())
    first = post_with_key(client, recipe("Soup"), key).json()
    assert client.delete(f"/v1/recipes/{first['id']}").status_code == 204
    # The request did happen; replaying it must not silently create the recipe again.
    retry = post_with_key(client, recipe("Soup"), key)
    assert retry.status_code == 201 and retry.json()["id"] == first["id"]
    assert "Location" not in retry.headers
    assert client.get("/v1/recipes").json()["items"] == []


def test_concurrent_requests_with_same_key_create_one_recipe(app, engine: Engine) -> None:
    key = str(uuid.uuid4())
    results: list[tuple[int, str]] = []
    barrier = threading.Barrier(3)

    def save() -> None:
        with TestClient(app) as c:
            barrier.wait()
            res = post_with_key(c, recipe("Soup"), key)
            results.append((res.status_code, res.json()["id"]))

    threads = [threading.Thread(target=save) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert [s for s, _ in results] == [201, 201, 201]
    assert len({rid for _, rid in results}) == 1
    assert count(engine, "recipes") == 1


def test_invalid_key_header_rejected(client: TestClient) -> None:
    assert_error(post_with_key(client, recipe("x"), "has space"), 422, "invalid_request")
    assert_error(post_with_key(client, recipe("x"), "k" * 256), 422, "invalid_request")
