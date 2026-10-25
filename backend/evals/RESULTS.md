# Extraction evals

`python -m evals.run anthropic` (from `backend/`) runs the real pipeline (`run_extraction`:
provider, deadline, one retry, validator) on the 30 cases in `evals/golden/`. It prints
a table by category and platform, writes every case to
`evals/results/<UTC timestamp>-<provider>.json`, and diffs against the previous file for
the same provider. `python -m evals.run fake` is free and offline. Case format and
labelling rules: [golden/README.md](golden/README.md). Metrics: `evals/scoring.py`.

**Re-run before merging any change to the extraction prompt, model or validator**, and
compare with the latest committed results file.

## Judge

Titles ("same dish?") and steps (1–5: are all expected steps covered, in a sensible
order?) are scored by an LLM judge, `evals/judge.py`, using **Claude Haiku 5.5**: the
project's extraction model, at low effort with structured output. It costs about $0.003 a
run. `--no-judge` (and the fake provider) use a deterministic fallback instead: fuzzy
title ratio ≥ 0.8, and fuzzy step coverage mapped to 1–5. Results files record which
scorer was used. Steps from the main recipe and its sub-recipes are compared in the order
they appear in the post, so a step filed under a different part isn't counted as out of
order.

## Baseline: 2026-10-25 (UTC), prompt-7, `claude-haiku-5-5`

Results file: `results/20261025T011855Z-anthropic.json`. 30 cases: 29 synthetic, 1 real.

| category | n | recipe | title | ing P | ing R | qty+unit | steps /5 | sub # | sub R | servings |
|---|---|---|---|---|---|---|---|---|---|---|
| **overall** | 30 | 100% | 92% | 100% | 99% | 95% | 4.92 | 80% | 100% | 100% |
| caption | 18 | 100% | 100% | 100% | 98% | 97% | 4.94 | 80% | 100% | 100% |
| transcript_only | 3 | 100% | 100% | 100% | 100% | 75% | 4.67 | – | – | – |
| comments | 3 | 100% | 33% | 100% | 100% | 100% | 5.00 | – | – | – |
| link_in_bio | 3 | 100% | 100% | 100% | 100% | 100% | – | – | – | – |
| not_a_recipe | 3 | 100% | – | – | – | – | – | – | – | – |
| sub_recipe | 4 | 100% | 100% | 100% | 96% | 94% | 4.75 | 100% | 100% | 100% |
| messy_formatting | 7 | 100% | 100% | 100% | 100% | 88% | 5.00 | 100% | 100% | 100% |
| instagram | 8 | 100% | 86% | 100% | 96% | 94% | 5.00 | 100% | 100% | 100% |
| tiktok | 8 | 100% | 86% | 100% | 100% | 89% | 4.83 | 100% | 100% | 100% |
| none (pasted) | 14 | 100% | 100% | 100% | 100% | 98% | 4.92 | 67% | 100% | 100% |

"–" means the metric doesn't apply to any case in the row. The prompt-injection case
left 0 injected words in unflagged rows; no extraction errors or timeouts. Latency was
4.8 s median and 13.8 s at most (the real reel). That's under the 30 s deadline, but the
slowest case is over the 10 s the retry needs, so a malformed reply on a post that long
wouldn't be retried.

**Cost:** 91,158 input / 22,038 output tokens for extraction ($0.0201), plus the judge
at 20,086 / 1,608 ($0.0028): **$0.023 a run**. Building this baseline took three live runs
($0.070 in all). The first two were discarded: one had a scorer bug (step order across
sub-recipes), and the other came before a labelling fix and a validator fix, both
described below.

**Fake (rule-based) baseline** for comparison, `results/20261025T011617Z-fake.json`:
37% recipe detection, 27% ingredient recall and 2.33 steps overall. It reads
header-and-bullet captions only, so transcripts, comments and sub-recipes all score 0.

### Run-to-run noise

Two back-to-back live runs on identical code moved 3 of 30 cases by more than 0.05
(e.g. `paragraph_only` named an ingredient "zest" instead of "lemons" in one run), and
overall ingredient recall by about 1 point. Treat differences of a point or two, or a
single case flipping, as noise: re-run, or use `--case ID` a few times, before calling
something a regression.

## What the misses were (baseline run)

1. **Vague-amount units are dropped (5 cases, most of the qty+unit misses).** "a splash
   of oat milk", "a handful of peanuts" and "a pinch of sugar" come back with
   `unit: null`; the labels say `splash`/`handful`/`pinch`. The validator keeps those
   units when the model returns them (a unit test covers it), so this is the model. It
   is also a labelling convention to settle: is "splash" a unit when there's no amount?
   Pick one and say it in the prompt.
2. **Ingredients named only inside a step:** "pita" (gyro) and "basil" (gnocchi) were
   missed. Prompt-7 asks for these; the same weakness shows in the old eval's
   RESULTS.md.
3. **Titles in casual captions (comments 33%):** "Best focaccia of my life" and "chili
   crisp fried eggs >>> recipe pinned…" got `title: null`. Prompt-7 says a title only if
   the post states the dish's name, so the model is being conservative and the label
   generous. Settle the convention.
4. **Sections that share one method** (`metric_sections`): the model made "Chicken" and
   "Rice" sub-recipes, which the label doesn't. Prompt-7's rule ("use a heading as a
   sub-recipe title when the part has its own ingredients") supports the model, so the
   prompt and the label disagree. Decide which is wanted.
5. **Unit after the name:** "1 garlic clove" came back without the unit.
6. **Step judge 4/5** on the tofu bowls and garlic bread: minor merges and splits.

**Fixed during this slice (after the first live run):**
- `canonical_unit` didn't recognise "cup of" (Haiku returned it for "one cup of frozen
  strawberries"). Those rows were flagged `unit_unknown` and kept "cup of". It now strips
  a trailing "of" (`app/extraction/quantities.py`, `tests/test_units.py`).
- `headers_bullets` was missing "butter", which is named in a step and counts under
  prompt-7's rules.

## What to do next

1. **Add real posts.** 29 of 30 cases are synthetic and the model aces most of them. The
   owner will paste 30–50 real Instagram and TikTok posts; label them per
   `golden/README.md`. Real captions are messier and will move these numbers more than
   any prompt tweak.
2. **Settle the three labelling conventions** above (vague-amount units, casual titles,
   shared-method sections). Then update the prompt or the labels, bump the prompt version,
   and re-run.
3. **Then, if needed, a prompt change** for ingredients named only in steps, measured
   against this baseline. Not done here on purpose.
4. The transcript and comment cases are only 3 each. Real "recipe in comments" posts,
   with many reaction comments, are the most valuable to add.
