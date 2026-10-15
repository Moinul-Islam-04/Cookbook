"""Score extraction providers on eval/captions.json through the real validator.

    .venv/bin/python -m eval.run_eval fake ollama        # from backend/
    .venv/bin/python -m eval.run_eval ollama --model qwen2.5:7b
    .venv/bin/python -m eval.run_eval ollama --case sections_with_own_steps --repeat 3

Expectations are hand-written. Metrics per provider:
- recipe: is_recipe detected correctly (a draft with no_recipe_found counts as "not a recipe")
- ingr recall: expected ingredient lines found in the draft (whitespace/case-insensitive)
- qty exact: of the found lines, quantity equals the expected value (None = no amount)
- invented: amounts/units the validator had to strip (quantity/unit_not_in_source)
- unmatched: ingredient/step rows flagged not_in_source (paraphrased or invented)
- steps: draft step count equals the expected count
- forbidden: injected words that made it into an unflagged row (must be 0)
"""

import argparse
import json
import re
import time
from decimal import Decimal
from pathlib import Path

from app.config import Settings
from app.extraction import ExtractionError, ExtractionTimeout, MalformedOutput, make_extractor, run_extraction

CASES = json.loads((Path(__file__).parent / "captions.json").read_text())


def norm(s: str) -> str:
    return re.sub(r"\s+", " ", s.lower()).strip(" .,-•")


def score(case: dict, draft) -> dict:
    found_recipe = not any(w.code == "no_recipe_found" for w in draft.warnings)
    r = {"recipe_ok": found_recipe == case["is_recipe"]}
    flagged_qty = sum(
        bool({"quantity_not_in_source", "unit_not_in_source"} & set(i.review_reasons)) for i in draft.ingredients
    )
    unmatched = sum("not_in_source" in i.review_reasons for i in draft.ingredients) + sum(
        "not_in_source" in s.review_reasons for s in draft.steps
    )
    r.update(invented=flagged_qty, unmatched=unmatched)
    if not case["is_recipe"]:
        r.update(found=0, expected=0, qty_ok=0, steps_ok=True, forbidden=0)
        return r
    by_raw = {norm(i.raw_text): i for i in draft.ingredients}
    found = qty_ok = 0
    for raw, qty in case["ingredients"]:
        hit = by_raw.get(norm(raw))
        if hit is None:
            continue
        found += 1
        want = None if qty is None else Decimal(str(qty))
        qty_ok += hit.quantity == want
    unflagged_text = " ".join(
        [i.raw_text for i in draft.ingredients if not i.needs_review]
        + [s.instruction for s in draft.steps if not s.needs_review]
        + [draft.title or ""]
    ).lower()
    r.update(
        found=found,
        expected=len(case["ingredients"]),
        qty_ok=qty_ok,
        steps_ok=len(draft.steps) == case["steps"],
        steps=len(draft.steps),
        headings_as_ingredients=sum(norm(h) in by_raw for h in case.get("not_ingredients", [])),
        forbidden=sum(w in unflagged_text for w in case.get("forbidden", []) if w not in case["caption"].lower().split("ai assistant")[0]),
    )
    return r


def run(provider: str, model: str | None) -> list[dict]:
    settings = Settings(extraction_provider=provider, **({"ollama_model": model} if model else {}))
    extractor = make_extractor(settings)
    rows = []
    for case in CASES:
        start = time.perf_counter()
        try:
            draft = run_extraction(extractor, case["caption"], settings.extraction_timeout_s)
            row = score(case, draft) | {"error": None}
        except (ExtractionError, ExtractionTimeout, MalformedOutput) as e:
            row = {"error": type(e).__name__, "recipe_ok": False, "found": 0, "expected": len(case.get("ingredients", [])),
                   "qty_ok": 0, "invented": 0, "unmatched": 0, "steps_ok": False, "forbidden": 0}
        row |= {"id": case["id"], "seconds": round(time.perf_counter() - start, 1)}
        rows.append(row)
        print(f"  {provider:7} {case['id']:22} {row['seconds']:5.1f}s  "
              f"recipe={'✓' if row['recipe_ok'] else '✗'} ingr={row['found']}/{row['expected']} qty={row['qty_ok']} "
              f"steps={'✓' if row['steps_ok'] else '✗'} invented={row['invented']} unmatched={row['unmatched']} "
              f"forbidden={row['forbidden']} headings={row.get('headings_as_ingredients', 0)} {row['error'] or ''}", flush=True)
    return rows


def summary(provider: str, rows: list[dict]) -> str:
    exp = sum(r["expected"] for r in rows)
    found = sum(r["found"] for r in rows)
    times = sorted(r["seconds"] for r in rows)
    return (
        f"{provider:22} recipe {sum(r['recipe_ok'] for r in rows)}/{len(rows)} | "
        f"ingredients {found}/{exp} | qty exact {sum(r['qty_ok'] for r in rows)}/{found} | "
        f"steps {sum(r['steps_ok'] for r in rows)}/{len(rows)} | invented-stripped {sum(r['invented'] for r in rows)} | "
        f"unmatched {sum(r['unmatched'] for r in rows)} | headings-as-ingredients {sum(r.get('headings_as_ingredients', 0) for r in rows)} | forbidden {sum(r['forbidden'] for r in rows)} | "
        f"errors {sum(bool(r['error']) for r in rows)} | median {times[len(times)//2]}s, max {times[-1]}s"
    )


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("providers", nargs="+")
    ap.add_argument("--model")
    ap.add_argument("--case", action="append", help="only these case ids (repeatable)")
    ap.add_argument("--repeat", type=int, default=1, help="run each case this many times")
    args = ap.parse_args()
    if args.case:
        unknown = set(args.case) - {c["id"] for c in CASES}
        if unknown:
            ap.error(f"unknown case id(s): {', '.join(sorted(unknown))}")
        CASES[:] = [c for c in CASES if c["id"] in args.case]
    CASES[:] = [c for c in CASES for _ in range(args.repeat)]
    results = {p: run(p, args.model) for p in args.providers}
    print()
    for p, rows in results.items():
        print(summary(p + (f":{args.model}" if args.model and p == "ollama" else ""), rows))
