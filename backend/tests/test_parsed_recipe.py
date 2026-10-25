"""Stages 3-4: RawPost → ParsedRecipe (validated DraftContent), against canned model output.

Covers the spec's hard cases: a recipe only in the transcript or the comments, "link in
bio", non-recipes, sub-recipes, messy formatting, and the retry on malformed output.
Live model wording is never asserted.
"""

import json
import time

import pytest
from fastapi.testclient import TestClient

from app.extraction import FakeExtractor, MalformedOutput, run_extraction
from app.extraction.source import render_post
from app.extraction.validate import validate_extraction
from app.ingest import RawPost
from app.schemas import DraftContent
from tests.test_import_drafts import _claude, _claude_message, use_fake
from tests.test_recipes_api import assert_error


def post(caption: str, transcript: str | None = None, comments: list[str] | None = None) -> RawPost:
    return RawPost(
        platform="tiktok", post_id="7301234567890123456", url="https://www.tiktok.com/@a/video/7301234567890123456",
        author_handle="a", caption=caption, transcript=transcript, top_comments=comments or [],
        media_urls=[], posted_at=None,
    )


def validate(p: RawPost | str, output: dict) -> DraftContent:
    return validate_extraction(json.dumps(output), p)


def codes(d: DraftContent) -> list[str]:
    return [w.code for w in d.warnings]


SPOKEN = post(
    "the 3 ingredient pasta everyone is making #pasta",
    transcript="Boil about 200 grams of spaghetti. Melt two tablespoons of butter and add a big handful of parmesan. "
    "Toss it all with a splash of pasta water.",
)


def test_recipe_only_in_the_transcript_keeps_spoken_amounts() -> None:
    d = validate(SPOKEN, {
        "is_recipe": True, "title": None, "source_fields_used": ["transcript"], "confidence": 0.8,
        "ingredients": [
            {"raw_text": "200 grams of spaghetti", "name": "spaghetti", "quantity": 200, "unit": "grams"},
            {"raw_text": "two tablespoons of butter", "name": "butter", "quantity": 2, "unit": "tablespoons"},
            {"raw_text": "a big handful of parmesan", "name": "parmesan", "quantity": None, "unit": "handful", "note": "big"},
            {"raw_text": "a splash of pasta water", "name": "pasta water", "quantity": None, "unit": "splash"},
        ],
        "steps": [{"instruction": "Boil about 200 grams of spaghetti."}, {"instruction": "Toss it all with a splash of pasta water."}],
    })
    rows = [(i.quantity, i.unit, i.name, i.note, i.needs_review) for i in d.ingredients]
    assert rows == [
        (200, "g", "spaghetti", None, False),
        (2, "tbsp", "butter", None, False),
        (None, "handful", "parmesan", "big", False),  # vague amount: no quantity
        (None, "splash", "pasta water", None, False),
    ]
    assert d.source_fields_used == ["transcript"] and not any(s.needs_review for s in d.steps)


def test_recipe_in_comments_and_unsupplied_fields_are_dropped_from_sources() -> None:
    p = post("Best focaccia 😍 recipe in the comments!", comments=["RECIPE: 500g bread flour, 400g water. Mix and rest overnight."])
    d = validate(p, {
        "is_recipe": True, "title": "focaccia", "source_fields_used": ["comments", "transcript"],
        "ingredients": [{"raw_text": "500g bread flour", "name": "bread flour", "quantity": 500, "unit": "g"},
                        {"raw_text": "400g water", "name": "water", "quantity": 400, "unit": "g"}],
        "steps": [{"instruction": "Mix and rest overnight."}],
    })
    assert not any(i.needs_review for i in d.ingredients)
    assert d.source_fields_used == ["comments"]  # no transcript was supplied
    assert d.title == "focaccia"


def test_link_in_bio_is_a_recipe_without_content() -> None:
    d = validate(post("Crispy rice salad 🥗 full recipe at the link in my bio!"), {
        "is_recipe": True, "title": "Crispy rice salad", "ingredients": [], "steps": [], "confidence": 0.1,
    })
    assert d.is_recipe and d.ingredients == [] and d.title is None
    assert codes(d) == ["no_recipe_found", "recipe_elsewhere"]
    assert d.confidence == 0.1


def test_mukbang_is_not_a_recipe() -> None:
    d = validate(post("eating the spiciest noodles in korea 🔥🔥 #mukbang"), {"is_recipe": False, "confidence": 0.95})
    assert not d.is_recipe and codes(d) == ["no_recipe_found"]


GYRO = (
    "Chicken gyros\n2 chicken thighs\n1 tsp oregano\nFor the tzatziki:\n1 cup greek yogurt\n½ cucumber, grated\n"
    "Grill the chicken. Mix the yogurt and cucumber. Wrap it all in a pita."
)


def test_sub_recipe_rows_are_flat_and_tagged() -> None:
    d = validate(GYRO, {
        "is_recipe": True, "title": "Chicken gyros",
        "ingredients": [{"raw_text": "2 chicken thighs", "name": "chicken thighs", "quantity": 2},
                        {"raw_text": "1 tsp oregano", "name": "oregano", "quantity": 1, "unit": "tsp"}],
        "steps": [{"instruction": "Grill the chicken."}, {"instruction": "Wrap it all in a pita."}],
        "sub_recipes": [
            {"title": "tzatziki",
             "ingredients": [{"raw_text": "1 cup greek yogurt", "name": "greek yogurt", "quantity": 1, "unit": "cup"},
                             {"raw_text": "½ cucumber, grated", "name": "cucumber", "quantity": 0.5, "note": "grated"}],
             "steps": [{"instruction": "Mix the yogurt and cucumber."}]},
            {"title": "Empty part", "ingredients": [], "steps": []},
            {"title": "Spicy Mayo", "ingredients": [{"raw_text": "1 tsp oregano", "name": "oregano"}], "steps": []},
        ],
    })
    assert [s.title for s in d.sub_recipes] == ["tzatziki", None]  # empty part dropped; unstated title cleared
    assert [(i.name, i.sub_recipe) for i in d.ingredients] == [
        ("chicken thighs", None), ("oregano", None), ("greek yogurt", 0), ("cucumber", 0), ("oregano", 1)]
    assert [(s.instruction, s.sub_recipe) for s in d.steps] == [
        ("Grill the chicken.", None), ("Wrap it all in a pita.", None), ("Mix the yogurt and cucumber.", 0)]
    cucumber = d.ingredients[3]
    assert (cucumber.quantity, cucumber.note, cucumber.needs_review) == (0.5, "grated", False)


def test_sub_recipe_alone_counts_as_a_recipe() -> None:
    d = validate(GYRO, {"is_recipe": True, "sub_recipes": [
        {"title": "tzatziki", "ingredients": [{"raw_text": "1 cup greek yogurt", "name": "greek yogurt"}], "steps": []}]})
    assert "no_recipe_found" not in codes(d) and d.ingredients[0].sub_recipe == 0


def test_messy_formatting_emoji_bullets_fractions_and_vague_amounts() -> None:
    caption = "🍋 Lemon bars\n🔸 1½ cups flour\n🔸 ¾ cup sugar\n🔸 a pinch of salt\n🔸 lemon zest to taste\nBake 20 min."
    d = validate(caption, {
        "is_recipe": True, "title": "Lemon bars",
        "ingredients": [
            {"raw_text": "1½ cups flour", "name": "flour", "quantity": 1.5, "unit": "cups"},
            {"raw_text": "¾ cup sugar", "name": "sugar", "quantity": 0.75, "unit": "cup"},
            {"raw_text": "a pinch of salt", "name": "salt", "quantity": None, "unit": "pinch"},
            {"raw_text": "lemon zest to taste", "name": "lemon zest", "quantity": None, "unit": None},
        ],
        "steps": [{"instruction": "Bake 20 min."}],
    })
    assert [(i.quantity, i.unit) for i in d.ingredients] == [(1.5, "cup"), (0.75, "cup"), (None, "pinch"), (None, None)]
    assert not any(i.needs_review for i in d.ingredients)


@pytest.mark.parametrize(
    "ingredient, reason, field, value",
    [
        ({"raw_text": "2 eggs", "name": "eggs", "quantity": -2}, "quantity_not_in_source", "quantity", None),
        ({"raw_text": "2 eggs", "name": "eggs", "quantity": 0}, "quantity_not_in_source", "quantity", None),
        ({"raw_text": "1 bowl rice", "name": "rice", "quantity": 1, "unit": "bowl"}, "unit_unknown", "unit", "bowl"),
        ({"raw_text": "2 eggs", "name": "eggs", "note": "beaten"}, "note_not_in_source", "note", None),
    ],
)
def test_sanity_checks_flag_rows(ingredient: dict, reason: str, field: str, value) -> None:
    caption = "2 eggs, 1 bowl rice. Fry it."
    d = validate(caption, {"is_recipe": True, "ingredients": [ingredient], "steps": [{"instruction": "Fry it."}]})
    row = d.ingredients[0]
    assert reason in row.review_reasons and row.needs_review
    assert getattr(row, field) == value


@pytest.mark.parametrize(
    "caption, servings, kept",
    [
        ("Serves 4. 2 eggs. Fry.", 4, 4),
        ("Makes about 12 cookies. 2 eggs. Fry.", 12, 12),
        ("This feeds four people. 2 eggs. Fry.", 4, 4),
        ("2 eggs. Fry.", 2, None),  # "2" is an amount, not servings
        ("Serves 4. 2 eggs. Fry.", 6, None),
        ("Serves 4. 2 eggs. Fry.", -4, None),
    ],
)
def test_servings_are_kept_only_when_stated(caption: str, servings: int, kept: int | None) -> None:
    d = validate(caption, {"is_recipe": True, "servings": servings, "ingredients": [{"raw_text": "2 eggs"}], "steps": [{"instruction": "Fry."}]})
    assert d.servings == kept


@pytest.mark.parametrize("claimed, stored, warned", [(1.7, 1.0, False), (-0.3, 0.0, True), (0.3, 0.3, True), (None, None, False)])
def test_confidence_is_clamped_and_low_confidence_warns(claimed, stored, warned) -> None:
    d = validate("2 eggs. Fry.", {"is_recipe": True, "confidence": claimed, "ingredients": [{"raw_text": "2 eggs"}], "steps": [{"instruction": "Fry."}]})
    assert d.confidence == stored and ("low_confidence" in codes(d)) == warned


def test_drafts_stored_before_parsed_recipe_still_load() -> None:
    old = {"title": "Soup", "ingredients": [{"raw_text": "salt", "name": "salt"}], "steps": [{"instruction": "Boil."}], "warnings": []}
    d = DraftContent.model_validate(old)
    assert d.is_recipe and d.sub_recipes == [] and d.ingredients[0].sub_recipe is None


GOOD = {"is_recipe": True, "ingredients": [{"raw_text": "2 eggs"}], "steps": [{"instruction": "Fry."}]}


def sequence(*responses):
    it = iter(responses)
    return lambda: next(it)


def test_malformed_output_is_retried_once() -> None:
    fake = FakeExtractor({"2 eggs. Fry.": sequence("not json", json.dumps(GOOD))})
    d = run_extraction(fake, "2 eggs. Fry.", 30)
    assert len(fake.calls) == 2 and d.ingredients[0].raw_text == "2 eggs"


def test_malformed_twice_gives_up(caplog) -> None:
    fake = FakeExtractor({"2 eggs. Fry.": sequence("not json", '{"is_recipe": "maybe"}')})
    with pytest.raises(MalformedOutput):
        run_extraction(fake, "2 eggs. Fry.", 30)
    assert len(fake.calls) == 2 and "giving up" in caplog.text


def test_no_retry_without_time_left() -> None:
    def slow_bad():
        time.sleep(0.2)
        return "not json"

    fake = FakeExtractor({"2 eggs. Fry.": slow_bad})
    with pytest.raises(MalformedOutput):
        run_extraction(fake, "2 eggs. Fry.", 10.1)  # under 10 s left after the first call
    assert len(fake.calls) == 1


def test_post_is_rendered_in_delimited_blocks() -> None:
    p = post("cap", transcript="spoken", comments=["c1", "c2"])
    assert render_post(p) == (
        "<caption>\ncap\n</caption>\n<transcript>\nspoken\n</transcript>\n"
        "<comments>\n<comment>\nc1\n</comment>\n<comment>\nc2\n</comment>\n</comments>"
    )
    assert render_post(post("cap")) == "<caption>\ncap\n</caption>"


def test_anthropic_adapter_sends_the_whole_post() -> None:
    import httpx2

    seen = {}

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.update(json.loads(request.content))
        return httpx2.Response(200, json=_claude_message(json.dumps(GOOD)))

    _claude(handler).extract(SPOKEN)
    content = seen["messages"][0]["content"]
    assert "<transcript>\nBoil about 200 grams" in content and content.startswith("<caption>\n")


GYRO_OUTPUT = {
    "is_recipe": True, "title": "Chicken gyros", "servings": None,
    "ingredients": [{"raw_text": "2 chicken thighs", "name": "chicken thighs", "quantity": 2}],
    "steps": [{"instruction": "Grill the chicken."}],
    "sub_recipes": [{"title": "tzatziki", "ingredients": [
        {"raw_text": "½ cucumber, grated", "name": "cucumber", "quantity": 0.5, "note": "grated"}],
        "steps": [{"instruction": "Mix the yogurt and cucumber."}]}],
}


def test_api_returns_sub_recipes_and_patch_keeps_tags(app, client: TestClient) -> None:
    use_fake(app, {GYRO: GYRO_OUTPUT})
    d = client.post("/v1/import-drafts", json={"source_text": GYRO}).json()
    assert d["sub_recipes"] == [{"title": "tzatziki"}]
    assert d["ingredients"][1]["note"] == "grated" and d["ingredients"][1]["sub_recipe"] == 0
    patched = client.patch(f"/v1/import-drafts/{d['id']}", json={
        "version": d["version"],
        "ingredients": [{"raw_text": "½ cucumber, grated", "name": "cucumber", "note": "grated", "sub_recipe": 0}],
    })
    assert patched.status_code == 200, patched.text
    assert patched.json()["ingredients"][0]["sub_recipe"] == 0

    bad = client.patch(f"/v1/import-drafts/{d['id']}", json={
        "version": patched.json()["version"], "steps": [{"instruction": "x", "sub_recipe": 3}]})
    assert_error(bad, 422, "invalid_request")
    assert bad.json()["field_errors"][0]["field"] == "steps.0.sub_recipe"


def test_api_sends_transcript_and_comments_to_the_extractor(app, client: TestClient) -> None:
    fake = use_fake(app, {})
    seen = []
    fake.fallback.extract = lambda p: seen.append(p) or json.dumps(GOOD)
    client.post("/v1/import-drafts", json={"source_text": "2 eggs. Fry.", "transcript": "spoken", "top_comments": ["c"]})
    assert seen[0].transcript == "spoken" and seen[0].top_comments == ["c"]
