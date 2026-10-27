"""Run the extraction eval on the golden set (evals/golden/*.json).

    .venv/bin/python -m evals.run fake                       # from backend/: offline, free
    .venv/bin/python -m evals.run anthropic                  # Claude Haiku + LLM judge; costs about $0.01
    .venv/bin/python -m evals.run anthropic --no-judge       # fuzzy title/step scoring instead of the judge
    .venv/bin/python -m evals.run anthropic --category transcript_only --case tiktok_spoken_pasta
    .venv/bin/python -m evals.run anthropic --synthetic-only # only the committed synthetic cases

Runs the real run_extraction (provider, deadline, retry, validator) on every case, prints
a summary by category, writes every case's output and scores to
evals/results/<UTC timestamp>-<provider>.json, and diffs against the previous results
file for the same provider. Re-run it before merging any change to the extraction prompt
or model (DECISIONS 2026-10-24).

Real posts are the main set. They live in evals/golden_real/, which git ignores (the repo
is public and they are other people's captions), and every run includes them when this
machine has them. A run with real posts writes to evals/results_real/ (also ignored),
since results repeat the captions; only --synthetic-only runs write to the committed
evals/results/. The summary scores real and synthetic cases separately.
"""

import argparse
import json
import os
import time
from datetime import UTC, datetime
from pathlib import Path

from app.config import Settings
from app.extraction import ExtractionError, ExtractionTimeout, MalformedOutput, make_extractor, run_extraction
from app.extraction.prompt import PROMPT_VERSION
from app.ingest import RawPost
from evals import scoring

ROOT = Path(__file__).parent
GOLDEN = ROOT / "golden"
RESULTS = ROOT / "results"
GOLDEN_REAL = ROOT / "golden_real"
RESULTS_REAL = ROOT / "results_real"
EXTRACTION_PRICES = {"claude-haiku-5-5": (0.10, 0.50)}  # USD per million (input, output) tokens
# Columns of the printed table: (metric, header, format).
COLUMNS = [
    ("is_recipe", "recipe", "{:.0%}"), ("title", "title", "{:.0%}"), ("ing_precision", "ing P", "{:.0%}"),
    ("ing_recall", "ing R", "{:.0%}"), ("qty_unit", "qty+unit", "{:.0%}"), ("steps", "steps/5", "{:.2f}"),
    ("sub_count", "sub #", "{:.0%}"), ("sub_recall", "sub R", "{:.0%}"), ("servings", "serv", "{:.0%}"),
    ("forbidden", "forbid", "{:.1f}"),
]


def load_cases(golden: Path = GOLDEN) -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted(golden.glob("*.json"))]


def load_real_cases() -> list[dict]:
    """The git-ignored real posts, if this machine has them."""
    return load_cases(GOLDEN_REAL) if GOLDEN_REAL.is_dir() else []


def case_categories(case: dict) -> list[str]:
    """The case's own categories, its platform ("none" for a pasted caption), and whether
    it's a real post or a synthetic one."""
    return list(case["categories"]) + [case["input"]["platform"] or "none",
                                       "synthetic" if case["synthetic"] else "real"]


def run(
    provider: str,
    *,
    cases: list[dict],
    use_judge: bool,
    results_dir: Path = RESULTS,
    settings: Settings | None = None,
    log=print,
) -> dict:
    settings = settings or Settings(extraction_provider=provider)
    extractor = make_extractor(settings)
    judge = None
    if use_judge:
        from evals.judge import Judge

        judge = Judge(settings.anthropic_api_key or os.environ["COOKBOOK_ANTHROPIC_API_KEY"])

    rows, tokens_in, tokens_out = [], 0, 0
    for case in cases:
        post = RawPost.model_validate(case["input"])
        if hasattr(extractor, "last_usage"):
            extractor.last_usage = None
        start = time.perf_counter()
        row = {"id": case["id"], "categories": case_categories(case), "synthetic": case["synthetic"], "error": None}
        try:
            draft = run_extraction(extractor, post, settings.extraction_timeout_s)
            parsed = scoring.draft_to_parsed(draft)
            scored = scoring.score_case(
                case,
                parsed,
                title_judge=judge.same_dish if judge else None,
                steps_judge=judge.steps_score if judge else None,
            )
            row["output"] = {k: v for k, v in parsed.items() if k != "unflagged_text"}
        except (ExtractionError, ExtractionTimeout, MalformedOutput) as e:
            scored = scoring.failed_case(case)
            row["error"] = type(e).__name__
            row["output"] = None
        row["seconds"] = round(time.perf_counter() - start, 2)
        usage = getattr(extractor, "last_usage", None)
        if usage:
            tokens_in, tokens_out = tokens_in + usage[0], tokens_out + usage[1]
        row |= scored | {"usage": usage, "score": scoring.case_score(scored["metrics"])}
        rows.append(row)
        m = row["metrics"]
        log(f"  {case['id']:36} {row['seconds']:5.1f}s  score={row['score']}  recipe={m['is_recipe']:.0f} "
            f"ingR={_fmt(m['ing_recall'])} qty={_fmt(m['qty_unit'])} steps={_fmt(m['steps'], '{:.1f}')} {row['error'] or ''}")

    model = getattr(extractor, "model", None)
    price = EXTRACTION_PRICES.get(model, (0, 0))
    extraction_cost = (tokens_in * price[0] + tokens_out * price[1]) / 1e6
    categories = sorted({c for r in rows for c in r["categories"]})
    result = {
        "provider": provider,
        "model": model,
        "extraction_version": extractor.version,
        "prompt_version": PROMPT_VERSION,
        "judge": judge.model if judge else "fuzzy (offline fallback)",
        "finished_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "summary": {"overall": scoring.aggregate(rows)}
        | {c: scoring.aggregate([r for r in rows if c in r["categories"]]) for c in categories},
        "cost": {
            "extraction_tokens": [tokens_in, tokens_out],
            "extraction_usd": round(extraction_cost, 5),
            "judge_tokens": [judge.input_tokens, judge.output_tokens] if judge else [0, 0],
            "judge_usd": round(judge.cost(), 5) if judge else 0.0,
        },
        "cases": rows,
    }
    previous = latest_results(results_dir, provider)
    results_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    path = results_dir / f"{stamp}-{provider}.json"
    path.write_text(json.dumps(result, indent=1, ensure_ascii=False, default=str) + "\n")
    result["path"] = str(path)
    log("")
    log(summary_table(result))
    log("")
    log(cost_line(result))
    log("")
    log(diff_text(previous, result) if previous else "No previous results for this provider; nothing to compare.")
    log(f"\nFull results: {path}")
    return result


def latest_results(results_dir: Path, provider: str) -> dict | None:
    files = sorted(results_dir.glob(f"*-{provider}.json"))
    return json.loads(files[-1].read_text()) if files else None


def _fmt(value, fmt="{:.0%}") -> str:
    return "  -" if value is None else fmt.format(value)


def summary_table(result: dict) -> str:
    head = f"{'category':18} {'n':>3} " + " ".join(f"{h:>8}" for _, h, _ in COLUMNS)
    lines = [head, "-" * len(head)]
    order = ["overall"] + sorted(k for k in result["summary"] if k != "overall")
    for name in order:
        agg = result["summary"][name]
        cells = " ".join(f"{_fmt(agg[m]['mean'], f):>8}" for m, _, f in COLUMNS)
        lines.append(f"{name:18} {agg['cases']:>3} {cells}" + (f"  errors={agg['errors']}" if agg["errors"] else ""))
    return "\n".join(lines)


def cost_line(result: dict) -> str:
    c = result["cost"]
    total = c["extraction_usd"] + c["judge_usd"]
    return (f"Cost: extraction {c['extraction_tokens'][0]} in / {c['extraction_tokens'][1]} out tokens (${c['extraction_usd']:.4f}), "
            f"judge {c['judge_tokens'][0]} in / {c['judge_tokens'][1]} out (${c['judge_usd']:.4f}); total ${total:.4f}")


def diff(previous: dict, current: dict, threshold: float = 0.05) -> dict:
    """Per-metric overall deltas, and cases whose score moved by more than `threshold`."""
    metrics = {}
    for m, _, _ in COLUMNS:
        a, b = previous["summary"]["overall"][m]["mean"], current["summary"]["overall"][m]["mean"]
        if a is not None and b is not None and abs(b - a) > 1e-9:
            metrics[m] = round(b - a, 4)
    before = {r["id"]: r["score"] for r in previous["cases"]}
    better, worse = [], []
    for r in current["cases"]:
        old, new = before.get(r["id"]), r["score"]
        if old is None or new is None:
            continue
        if new - old > threshold:
            better.append((r["id"], old, new))
        elif old - new > threshold:
            worse.append((r["id"], old, new))
    added = sorted(set(r["id"] for r in current["cases"]) - set(before))
    return {"metrics": metrics, "better": better, "worse": worse, "new_cases": added}


def diff_text(previous: dict, current: dict) -> str:
    d = diff(previous, current)
    lines = [f"Compared with {previous['finished_at']} ({previous['extraction_version']}):"]
    lines.append("  metrics: " + (", ".join(f"{m} {v:+.3f}" for m, v in d["metrics"].items()) or "no change"))
    for label, items in (("better", d["better"]), ("worse", d["worse"])):
        for cid, old, new in items:
            lines.append(f"  {label:6} {cid}: {old} -> {new}")
    if d["new_cases"]:
        lines.append("  new cases: " + ", ".join(d["new_cases"]))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> dict:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("provider", choices=["fake", "anthropic"])
    ap.add_argument("--no-judge", action="store_true", help="score titles and steps with fuzzy matching (no API calls)")
    ap.add_argument("--case", action="append", help="only these case ids (repeatable)")
    ap.add_argument("--category", action="append", help="only cases in these categories (repeatable)")
    ap.add_argument("--synthetic-only", action="store_true", help="skip the real posts in evals/golden_real/")
    ap.add_argument("--results-dir", type=Path,
                    help="default: evals/results_real/ when real posts run, else evals/results/")
    args = ap.parse_args(argv)
    cases = load_cases()
    private_ids = set() if args.synthetic_only else {c["id"] for c in load_real_cases()}
    if not args.synthetic_only:
        cases += load_real_cases()
    if args.case:
        unknown = set(args.case) - {c["id"] for c in cases}
        if unknown:
            ap.error(f"unknown case id(s): {', '.join(sorted(unknown))}")
        cases = [c for c in cases if c["id"] in args.case]
    if args.category:
        cases = [c for c in cases if set(args.category) & set(case_categories(c))]
    if not cases:
        ap.error("no cases selected")
    # The judge needs the API, so it's on only for the hosted provider unless turned off.
    use_judge = args.provider == "anthropic" and not args.no_judge
    # Results repeat each case's input, so a run with private cases stays out of git.
    has_private = any(c["id"] in private_ids for c in cases)
    results_dir = args.results_dir or (RESULTS_REAL if has_private else RESULTS)
    return run(args.provider, cases=cases, use_judge=use_judge, results_dir=results_dir)


if __name__ == "__main__":
    main()
