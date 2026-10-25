"""Per-case metrics for the extraction eval (Andrew's spec), as pure functions.

What's scored is the *validated* draft (app/extraction/validate.py output), so the score
reflects what a user would see, after the server's fidelity checks.

| metric        | how                                                                   |
|---------------|-----------------------------------------------------------------------|
| is_recipe     | exact match with the model's verdict (1/0)                            |
| title         | fuzzy ratio after normalizing; or an LLM judge's "same dish?" (1/0)   |
| ing_precision | name matches / ingredients returned (all rows, sub-recipes included)  |
| ing_recall    | name matches / ingredients expected                                   |
| qty_unit      | of name-matched rows, quantity and unit both exact                    |
| steps         | 1-5: an LLM judge, or a deterministic fuzzy coverage score (labelled) |
| sub_count     | number of sub-recipes matches (1/0)                                   |
| sub_recall    | ingredient-name recall inside matched sub-recipes                     |
| servings      | exact match                                                           |
| forbidden     | injected words in rows the validator didn't flag (lower is better)    |

A metric is None when it doesn't apply (e.g. ingredient recall for a non-recipe), and
None values are left out of averages. Names are matched after lowercasing, dropping
punctuation and naive singularizing ("cloves" -> "clove"); a name that contains the other
("garlic" / "garlic cloves") also matches.
"""

import re
from collections.abc import Callable
from difflib import SequenceMatcher

from app.schemas import DraftContent

TITLE_MATCH = 0.8  # fuzzy ratio at or above this counts as the same title
STEP_MATCH = 0.6  # fuzzy ratio for an expected step to count as covered
QTY_TOLERANCE = 0.002

METRICS = ["is_recipe", "title", "ing_precision", "ing_recall", "qty_unit", "steps", "sub_count", "sub_recall", "servings", "forbidden"]


# ---------- normalizing ----------


def _singular(word: str) -> str:
    if len(word) > 4 and word.endswith("ies"):
        return word[:-3] + "y"
    if len(word) > 3 and word.endswith(("oes", "ches", "shes")):
        return word[:-2]
    if len(word) > 3 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


def norm_name(name: str | None) -> str:
    words = re.sub(r"[^a-z0-9 ]+", " ", (name or "").lower()).split()
    return " ".join(_singular(w) for w in words)


def norm_text(text: str | None) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]+", " ", (text or "").lower())).strip()


def ratio(a: str | None, b: str | None) -> float:
    return SequenceMatcher(None, norm_text(a), norm_text(b)).ratio()


# ---------- turning a draft back into a ParsedRecipe-shaped dict ----------


def draft_to_parsed(draft: DraftContent) -> dict:
    """Rebuild sub-recipes from the flat draft by grouping rows on their `sub_recipe` index."""

    def ing(i):
        return {"raw_text": i.raw_text, "name": i.name, "quantity": None if i.quantity is None else float(i.quantity),
                "unit": i.unit, "note": i.note, "needs_review": i.needs_review}

    subs = [{"title": s.title, "ingredients": [], "steps": []} for s in draft.sub_recipes]
    main = {"ingredients": [], "steps": []}
    for i in draft.ingredients:
        (main if i.sub_recipe is None or i.sub_recipe >= len(subs) else subs[i.sub_recipe])["ingredients"].append(ing(i))
    for s in draft.steps:
        (main if s.sub_recipe is None or s.sub_recipe >= len(subs) else subs[s.sub_recipe])["steps"].append(s.instruction)
    return {
        "is_recipe": draft.is_recipe,
        "title": draft.title,
        "servings": draft.servings,
        "ingredients": main["ingredients"],
        "steps": main["steps"],
        "sub_recipes": subs,
        "confidence": draft.confidence,
        "source_fields_used": draft.source_fields_used,
        "warnings": [w.code for w in draft.warnings],
        "unflagged_text": " ".join(
            [i.raw_text for i in draft.ingredients if not i.needs_review]
            + [s.instruction for s in draft.steps if not s.needs_review]
            + [draft.title or ""]
        ).lower(),
    }


def all_ingredients(parsed: dict) -> list[dict]:
    return parsed["ingredients"] + [i for s in parsed["sub_recipes"] for i in s["ingredients"]]


def all_steps(parsed: dict) -> list[str]:
    return parsed["steps"] + [st for s in parsed["sub_recipes"] for st in s["steps"]]


def post_text(post: dict) -> str:
    return norm_text("\n".join([post.get("caption") or "", post.get("transcript") or "", *post.get("top_comments", [])]))


def in_post_order(steps: list[str], source: str) -> list[str]:
    """Steps sorted by where they appear in the post.

    Main and sub-recipe steps are flattened before comparing, so without this a step the
    model filed under another part (or the label's main-then-sub order) would look out of
    order. A step not found word for word keeps its place after the step before it.
    """
    if not source:
        return steps
    keyed, last = [], -1.0
    for i, step in enumerate(steps):
        pos = source.find(norm_text(step)) if norm_text(step) else -1
        last = float(pos) if pos >= 0 else last + 1e-3
        keyed.append((last, i, step))
    return [step for _, _, step in sorted(keyed)]


# ---------- metrics ----------


def match_ingredients(expected: list[dict], got: list[dict]) -> list[tuple[dict, dict]]:
    """Greedy one-to-one name matching: exact normalized names first, then containment."""
    pairs, used = [], set()
    for exact in (True, False):
        for e in expected:
            if any(e is p[0] for p in pairs):
                continue
            en = norm_name(e["name"])
            for j, g in enumerate(got):
                if j in used:
                    continue
                gn = norm_name(g["name"])
                if not en or not gn:
                    continue
                if en == gn if exact else (en in gn or gn in en):
                    pairs.append((e, g))
                    used.add(j)
                    break
    return pairs


def ingredient_scores(expected: list[dict], got: list[dict]) -> dict:
    pairs = match_ingredients(expected, got)
    precision = len(pairs) / len(got) if got else (1.0 if not expected else None)
    recall = len(pairs) / len(expected) if expected else None
    qty_ok = [
        (e["quantity"] is None) == (g["quantity"] is None)
        and (e["quantity"] is None or abs(e["quantity"] - g["quantity"]) <= QTY_TOLERANCE)
        and (e["unit"] or None) == (g["unit"] or None)
        for e, g in pairs
    ]
    return {
        "ing_precision": precision,
        "ing_recall": recall,
        "qty_unit": sum(qty_ok) / len(qty_ok) if qty_ok else None,
        "matched": len(pairs),
        "qty_misses": [
            {"name": e["name"], "expected": [e["quantity"], e["unit"]], "got": [g["quantity"], g["unit"]]}
            for (e, g), ok in zip(pairs, qty_ok) if not ok
        ],
        "missing": [e["name"] for e in expected if not any(e is p[0] for p in pairs)],
        "extra": [g["name"] for g in got if not any(g is p[1] for p in pairs)],
    }


def title_score(expected: str | None, got: str | None, judge: Callable[[str, str], bool] | None = None) -> float | None:
    if expected is None:
        return 1.0 if got is None else None  # a stated title the label didn't name isn't scored
    if got is None:
        return 0.0
    if judge is not None:
        return 1.0 if judge(expected, got) else 0.0
    return 1.0 if ratio(expected, got) >= TITLE_MATCH else 0.0


def fuzzy_steps_score(expected: list[str], got: list[str]) -> float | None:
    """Deterministic stand-in for the LLM step judge, on the same 1-5 scale.

    Coverage: share of expected steps whose best fuzzy match in `got` is >= STEP_MATCH.
    Order: share of consecutive covered steps whose matches appear in order. Score is
    1 + 4 * coverage, minus 1 (not below 1) if the order is broken.
    """
    if not expected:
        return None  # nothing to cover (e.g. "link in bio"); invented steps show up in review flags
    if not got:
        return 1.0
    best = []
    for e in expected:
        scores = [ratio(e, g) for g in got]
        j = max(range(len(got)), key=scores.__getitem__)
        if scores[j] >= STEP_MATCH:
            best.append(j)
    coverage = len(best) / len(expected)
    in_order = all(a <= b for a, b in zip(best, best[1:]))
    return round(max(1.0, 1 + 4 * coverage - (0 if in_order else 1)), 2)


def sub_recipe_scores(expected: list[dict], got: list[dict]) -> dict:
    if not expected and not got:
        return {"sub_count": None, "sub_recall": None}
    # Pair by title when both have one, then by position for the rest.
    pairs, used = [], set()
    for e in expected:
        best = max(
            ((j, ratio(e["title"], g["title"])) for j, g in enumerate(got) if j not in used and e["title"] and g["title"]),
            key=lambda t: t[1], default=None,
        )
        if best and best[1] >= TITLE_MATCH:
            pairs.append((e, got[best[0]]))
            used.add(best[0])
    for e in expected:
        if any(e is p[0] for p in pairs):
            continue
        j = next((j for j in range(len(got)) if j not in used), None)
        if j is not None:
            pairs.append((e, got[j]))
            used.add(j)
    recalls = [ingredient_scores(e["ingredients"], g["ingredients"])["ing_recall"] for e, g in pairs]
    recalls = [r for r in recalls if r is not None]
    return {
        "sub_count": 1.0 if len(expected) == len(got) else 0.0,
        "sub_recall": (sum(recalls) / len(expected)) if expected else None,
    }


def score_case(
    case: dict,
    parsed: dict,
    *,
    title_judge: Callable[[str, str], bool] | None = None,
    steps_judge: Callable[[list[str], list[str]], int] | None = None,
) -> dict:
    exp = case["expected"]
    metrics = {"is_recipe": 1.0 if parsed["is_recipe"] == exp["is_recipe"] else 0.0}
    details: dict = {}
    if not exp["is_recipe"]:
        # Only the verdict matters, but rows extracted from a non-recipe are a false positive.
        got = all_ingredients(parsed)
        metrics |= {m: None for m in METRICS if m not in metrics}
        metrics["ing_precision"] = 0.0 if got else None
        details["extra"] = [g["name"] for g in got]
        return {"metrics": metrics, "details": details}

    ing = ingredient_scores(all_ingredients(exp), all_ingredients(parsed))
    metrics["ing_precision"], metrics["ing_recall"], metrics["qty_unit"] = ing["ing_precision"], ing["ing_recall"], ing["qty_unit"]
    details |= {k: ing[k] for k in ("missing", "extra", "qty_misses")}

    metrics["title"] = title_score(exp["title"], parsed["title"], title_judge)

    source = post_text(case.get("input") or {})
    exp_steps, got_steps = in_post_order(all_steps(exp), source), in_post_order(all_steps(parsed), source)
    if steps_judge is not None and exp_steps:
        metrics["steps"] = float(steps_judge(exp_steps, got_steps)) if got_steps else 1.0
    else:
        metrics["steps"] = fuzzy_steps_score(exp_steps, got_steps)

    metrics |= sub_recipe_scores(exp["sub_recipes"], parsed["sub_recipes"])
    if exp["servings"] is not None or parsed["servings"] is not None:
        metrics["servings"] = 1.0 if exp["servings"] == parsed["servings"] else 0.0
    else:
        metrics["servings"] = None
    forbidden = case.get("forbidden", [])
    metrics["forbidden"] = float(sum(w in parsed["unflagged_text"] for w in forbidden)) if forbidden else None
    return {"metrics": metrics, "details": details}


def failed_case(case: dict) -> dict:
    """An extraction error scores as a total miss on everything that applies."""
    exp = case["expected"]
    metrics = {m: None for m in METRICS}
    metrics["is_recipe"] = 0.0
    if exp["is_recipe"]:
        metrics |= {"ing_recall": 0.0 if all_ingredients(exp) else None, "qty_unit": None, "steps": 1.0 if all_steps(exp) else None,
                    "title": 0.0 if exp["title"] else None}
        if exp["sub_recipes"]:
            metrics |= {"sub_count": 0.0, "sub_recall": 0.0}
    return {"metrics": metrics, "details": {}}


def case_score(metrics: dict) -> float | None:
    """One number per case for "better/worse" diffs: the mean of the 0-1 core metrics
    (steps rescaled from 1-5)."""
    vals = []
    for m in ("is_recipe", "title", "ing_precision", "ing_recall", "qty_unit", "sub_count", "sub_recall", "servings"):
        if metrics.get(m) is not None:
            vals.append(metrics[m])
    if metrics.get("steps") is not None:
        vals.append((metrics["steps"] - 1) / 4)
    return round(sum(vals) / len(vals), 4) if vals else None


def aggregate(rows: list[dict]) -> dict:
    """Mean of each metric over the rows where it applies, plus how many rows applied."""
    out = {}
    for m in METRICS:
        vals = [r["metrics"][m] for r in rows if r["metrics"].get(m) is not None]
        out[m] = {"mean": round(sum(vals) / len(vals), 4) if vals else None, "n": len(vals)}
    out["cases"] = len(rows)
    out["errors"] = sum(bool(r.get("error")) for r in rows)
    return out
