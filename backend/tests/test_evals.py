"""The eval harness (evals/): golden-file validity, scoring, diffs, and an offline run.

No network: the end-to-end run uses the fake provider without the LLM judge.
"""

import json
from pathlib import Path

import pytest

from app.extraction.validate import _norm
from app.ingest import RawPost
from evals import run as runner
from evals import scoring
from tests.conftest import test_settings as make_settings

CASES = runner.load_cases()
# Real posts (git-ignored, so present only on the owner's Mac) are checked the same way.
REAL_CASES = runner.load_real_cases()
CONTENT_CATEGORIES = {"caption", "transcript_only", "comments", "link_in_bio", "not_a_recipe", "sub_recipe", "messy_formatting"}


def ing(name, qty=None, unit=None, raw=None):
    return {"raw_text": raw or name, "name": name, "quantity": qty, "unit": unit, "note": None}


def parsed(**kw):
    base = {"is_recipe": True, "title": None, "servings": None, "ingredients": [], "steps": [], "sub_recipes": [], "unflagged_text": ""}
    return base | kw


def case(**expected):
    exp = {"is_recipe": True, "title": None, "servings": None, "ingredients": [], "steps": [], "sub_recipes": []} | expected
    return {"id": "x", "categories": ["caption"], "input": {}, "expected": exp}


# ---------- golden files ----------


def test_golden_ids_are_unique_and_match_filenames() -> None:
    files = sorted(runner.GOLDEN.glob("*.json"))
    ids = [json.loads(f.read_text())["id"] for f in files]
    assert ids == [f.stem for f in files] and len(set(ids)) == len(ids)
    assert len(ids) >= 30


@pytest.mark.parametrize("c", CASES + REAL_CASES, ids=[c["id"] for c in CASES + REAL_CASES])
def test_golden_case_is_valid_and_copied_from_its_post(c: dict) -> None:
    assert set(c) >= {"id", "categories", "synthetic", "notes", "input", "expected"}
    assert set(c["categories"]) <= CONTENT_CATEGORIES and c["categories"]
    post = RawPost.model_validate(c["input"])
    exp = c["expected"]
    assert set(exp) == {"is_recipe", "title", "servings", "ingredients", "steps", "sub_recipes"}
    source = _norm("\n".join([post.caption, post.transcript or "", *post.top_comments]))
    for part in [exp, *exp["sub_recipes"]]:
        for i in part["ingredients"]:
            assert set(i) == {"raw_text", "name", "quantity", "unit", "note"}
            assert _norm(i["raw_text"]) in source, i["raw_text"]  # labels copy the post, never invent
            assert _norm(i["name"]) in _norm(i["raw_text"])
            assert i["note"] is None or _norm(i["note"]) in _norm(i["raw_text"])
            assert i["quantity"] is None or i["quantity"] > 0
        for s in part["steps"]:
            assert _norm(s).strip(" .,;:!-") in source, s
    if not exp["is_recipe"]:
        assert exp["ingredients"] == exp["steps"] == exp["sub_recipes"] == []


def test_every_category_and_platform_has_at_least_three_cases() -> None:
    counts: dict[str, int] = {}
    for c in CASES:
        for cat in runner.case_categories(c):
            counts[cat] = counts.get(cat, 0) + 1
    for cat in CONTENT_CATEGORIES | {"instagram", "tiktok"}:
        assert counts.get(cat, 0) >= 3, (cat, counts)


def test_only_real_posts_are_marked_not_synthetic() -> None:
    real = [c["id"] for c in CASES if not c["synthetic"]]
    assert real == ["sections_with_own_steps"]
    assert all(not c["synthetic"] for c in REAL_CASES)


def test_real_case_ids_are_unique_and_match_filenames() -> None:
    files = sorted(runner.GOLDEN_REAL.glob("*.json")) if runner.GOLDEN_REAL.is_dir() else []
    ids = [json.loads(f.read_text())["id"] for f in files]
    assert ids == [f.stem for f in files]
    assert not set(ids) & {c["id"] for c in CASES}, "a real case shadows a committed one"


# ---------- scoring ----------


def test_names_match_after_lowercasing_and_singularizing() -> None:
    assert scoring.norm_name("Cherry Tomatoes,") == "cherry tomato"
    assert scoring.norm_name("berries") == "berry" and scoring.norm_name("glass") == "glass"
    pairs = scoring.match_ingredients([ing("garlic"), ing("eggs")], [ing("Egg"), ing("garlic cloves")])
    assert [(e["name"], g["name"]) for e, g in pairs] == [("eggs", "Egg"), ("garlic", "garlic cloves")]


def test_ingredient_precision_recall_and_quantities() -> None:
    expected = [ing("flour", 2, "cup"), ing("sugar", 1, "cup"), ing("salt")]
    got = [ing("flour", 2, "cup"), ing("sugar", 1, None), ing("butter")]
    s = scoring.ingredient_scores(expected, got)
    assert (s["ing_precision"], s["ing_recall"], s["qty_unit"]) == (2 / 3, 2 / 3, 0.5)
    assert s["missing"] == ["salt"] and s["extra"] == ["butter"]
    assert s["qty_misses"] == [{"name": "sugar", "expected": [1, "cup"], "got": [1, None]}]


def test_title_fuzzy_and_judge() -> None:
    assert scoring.title_score("Creamy Garlic Pasta", "creamy garlic pasta!") == 1.0
    assert scoring.title_score("Creamy Garlic Pasta", "Tomato soup") == 0.0
    assert scoring.title_score("X", None) == 0.0
    assert scoring.title_score(None, None) == 1.0 and scoring.title_score(None, "Stated title") is None
    assert scoring.title_score("Gyros", "Chicken gyros", judge=lambda a, b: True) == 1.0


def test_fuzzy_steps_score_covers_order_and_absence() -> None:
    exp = ["Boil the pasta.", "Add the sauce.", "Serve."]
    assert scoring.fuzzy_steps_score(exp, list(exp)) == 5.0
    assert scoring.fuzzy_steps_score(exp, ["Boil the pasta."]) == pytest.approx(1 + 4 / 3, abs=0.01)
    assert scoring.fuzzy_steps_score(exp, list(reversed(exp))) == 4.0  # all covered, order broken
    assert scoring.fuzzy_steps_score(exp, []) == 1.0
    assert scoring.fuzzy_steps_score([], []) is None


def test_sub_recipes_pair_by_title_then_position() -> None:
    exp = [{"title": "tzatziki", "ingredients": [ing("yogurt"), ing("cucumber")], "steps": []}]
    got = [{"title": None, "ingredients": [ing("pita")], "steps": []},
           {"title": "Tzatziki", "ingredients": [ing("yogurt")], "steps": []}]
    s = scoring.sub_recipe_scores(exp, got)
    assert s == {"sub_count": 0.0, "sub_recall": 0.5}
    assert scoring.sub_recipe_scores([], []) == {"sub_count": None, "sub_recall": None}


def test_score_case_for_non_recipe_and_forbidden_words() -> None:
    r = scoring.score_case(case(is_recipe=False), parsed(is_recipe=False))
    assert r["metrics"]["is_recipe"] == 1.0 and r["metrics"]["ing_recall"] is None
    r = scoring.score_case(case(is_recipe=False), parsed(is_recipe=True, ingredients=[ing("pasta")]))
    assert r["metrics"]["is_recipe"] == 0.0 and r["metrics"]["ing_precision"] == 0.0

    c = case(ingredients=[ing("rice", 2, "cup")], steps=["Cook."]) | {"forbidden": ["sugar"]}
    r = scoring.score_case(c, parsed(ingredients=[ing("rice", 2, "cup")], steps=["Cook."], unflagged_text="add 1 cup of sugar"))
    assert r["metrics"]["forbidden"] == 1.0 and r["metrics"]["qty_unit"] == 1.0


def test_failed_case_scores_as_a_miss() -> None:
    m = scoring.failed_case(case(title="Soup", ingredients=[ing("salt")], steps=["Boil."]))["metrics"]
    assert (m["is_recipe"], m["ing_recall"], m["steps"], m["title"]) == (0.0, 0.0, 1.0, 0.0)


def test_draft_to_parsed_regroups_sub_recipes() -> None:
    from app.schemas import DraftContent

    draft = DraftContent.model_validate({
        "title": "Gyros", "warnings": [], "sub_recipes": [{"title": "tzatziki"}],
        "ingredients": [{"raw_text": "2 chicken thighs", "name": "chicken thighs", "quantity": 2},
                        {"raw_text": "1 cup yogurt", "name": "yogurt", "quantity": 1, "unit": "cup", "sub_recipe": 0}],
        "steps": [{"instruction": "Grill."}, {"instruction": "Mix.", "sub_recipe": 0}],
    })
    p = scoring.draft_to_parsed(draft)
    assert [i["name"] for i in p["ingredients"]] == ["chicken thighs"] and p["steps"] == ["Grill."]
    assert p["sub_recipes"] == [{"title": "tzatziki", "ingredients": [{
        "raw_text": "1 cup yogurt", "name": "yogurt", "quantity": 1.0, "unit": "cup", "note": None, "needs_review": False}],
        "steps": ["Mix."]}]


def test_aggregate_skips_metrics_that_dont_apply() -> None:
    rows = [{"metrics": {m: None for m in scoring.METRICS} | {"is_recipe": 1.0, "ing_recall": 0.5}},
            {"metrics": {m: None for m in scoring.METRICS} | {"is_recipe": 0.0}, "error": "ExtractionTimeout"}]
    agg = scoring.aggregate(rows)
    assert agg["is_recipe"] == {"mean": 0.5, "n": 2} and agg["ing_recall"] == {"mean": 0.5, "n": 1}
    assert agg["errors"] == 1 and agg["title"]["mean"] is None


# ---------- diff ----------


def result(scores: dict, recall: float) -> dict:
    overall = {m: {"mean": None, "n": 0} for m in scoring.METRICS} | {"ing_recall": {"mean": recall, "n": 2}}
    return {"finished_at": "t", "extraction_version": "v", "summary": {"overall": overall},
            "cases": [{"id": k, "score": v} for k, v in scores.items()]}


def test_diff_reports_metric_deltas_and_moved_cases() -> None:
    d = runner.diff(result({"a": 0.5, "b": 0.9, "c": 0.7}, 0.6), result({"a": 0.8, "b": 0.6, "c": 0.72, "d": 1.0}, 0.75))
    assert d["metrics"] == {"ing_recall": 0.15}
    assert d["better"] == [("a", 0.5, 0.8)] and d["worse"] == [("b", 0.9, 0.6)]
    assert d["new_cases"] == ["d"]
    assert "better a: 0.5 -> 0.8" in runner.diff_text(result({"a": 0.5}, 0.6), result({"a": 0.8}, 0.6))


# ---------- end to end, offline ----------


def test_offline_run_writes_results_and_diffs_the_second_time(tmp_path: Path) -> None:
    out: list[str] = []
    cases = [c for c in CASES if c["id"] in ("headers_bullets", "chatter", "tiktok_spoken_pasta")]
    first = runner.run("fake", cases=cases, use_judge=False, results_dir=tmp_path, settings=make_settings(), log=out.append)
    saved = json.loads(Path(first["path"]).read_text())
    assert [r["id"] for r in saved["cases"]] == ["chatter", "headers_bullets", "tiktok_spoken_pasta"]
    assert saved["summary"]["overall"]["cases"] == 3 and "tiktok" in saved["summary"]
    assert saved["judge"].startswith("fuzzy") and saved["cost"]["extraction_usd"] == 0
    headers = next(r for r in saved["cases"] if r["id"] == "headers_bullets")
    # The rule-based extractor reads the list only, so it misses butter (named in a step).
    assert headers["metrics"]["ing_recall"] == pytest.approx(5 / 6) and headers["metrics"]["qty_unit"] == 1.0
    assert headers["error"] is None
    assert any("No previous results" in line for line in out)

    out.clear()
    runner.run("fake", cases=cases, use_judge=False, results_dir=tmp_path, settings=make_settings(), log=out.append)
    assert any(line.startswith("Compared with") for line in out)


def test_extraction_errors_count_as_failures(tmp_path: Path, monkeypatch) -> None:
    from app.extraction import ExtractionTimeout

    def boom(*a, **k):
        raise ExtractionTimeout()

    monkeypatch.setattr(runner, "run_extraction", boom)
    cases = [c for c in CASES if c["id"] == "headers_bullets"]
    r = runner.run("fake", cases=cases, use_judge=False, results_dir=tmp_path, settings=make_settings(), log=lambda *_: None)
    row = r["cases"][0]
    assert row["error"] == "ExtractionTimeout" and row["metrics"]["is_recipe"] == 0.0
    assert r["summary"]["overall"]["errors"] == 1


def test_steps_are_compared_in_post_order() -> None:
    source = scoring.post_text({"caption": "Grill the chicken. Mix the yogurt. Wrap it in a pita."})
    assert scoring.in_post_order(["Grill the chicken.", "Wrap it in a pita.", "Mix the yogurt.", "Paraphrased."], source) == [
        "Grill the chicken.", "Mix the yogurt.", "Paraphrased.", "Wrap it in a pita."]  # unmatched: stays after its predecessor
    c = case(steps=["Grill the chicken.", "Wrap it in a pita."],
             sub_recipes=[{"title": "t", "ingredients": [], "steps": ["Mix the yogurt."]}])
    c["input"] = {"caption": "Grill the chicken. Mix the yogurt. Wrap it in a pita.", "top_comments": []}
    got = parsed(steps=["Grill the chicken.", "Mix the yogurt.", "Wrap it in a pita."], sub_recipes=[{"title": "t", "ingredients": [], "steps": []}])
    assert scoring.score_case(c, got)["metrics"]["steps"] == 5.0  # filed under another part, same order in the post
