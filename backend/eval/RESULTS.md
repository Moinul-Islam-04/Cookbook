# Extraction evaluation

`eval/captions.json` holds 14 hand-labelled captions (13 written for the eval, plus one
real reel that failed in the app; see the 2026-10-15 run below):
- headers and bullets, inline prose, a comma list with no headers, emoji bullets with
  Unicode fractions
- metric amounts in sections, ranges and vague amounts, a single paragraph
- two non-recipes (a "recipe in bio" post and chatter)
- a prompt injection, a contradictory edit, and missing amounts

`python -m eval.run_eval fake ollama` scores each provider through the real validator.

Run on 2026-10-14 with an Apple M2 and 16 GB RAM, Ollama 0.40.4, `qwen2.5:7b`, prompt-3:

| | Fake (rules) | Qwen 2.5 7B |
|---|---|---|
| Recipe vs non-recipe correct | 8/12 | **12/12** |
| Expected ingredients found | 23/50 | **47/50** |
| Quantity exact (of found) | 23/23 | 46/47 |
| Step count matches | 5/12 | 10/12 |
| Amounts/units the validator stripped | 0 | 4 (all from one bad response) |
| Injected words in an unflagged row | 3 | **0** |
| Errors / timeouts | 0 | 0 |
| Median / max latency | 0 s | 29.5 s / 42 s |

## What the evaluation changed

The first Qwen run scored 11/12, 44/50, 37/44 and timed out once. These fixes came from
reading its raw output:

- **Validator too strict (my bugs):**
  - `500g` failed the whole-word unit check, and so did `cup` against "cups".
  - A model's `0.33` for "1/3" was rejected. It now maps to the caption's exact 0.333.
- **Model leaves fields empty:** `name` was null on every row, and some quantities were
  missing. The validator now fills empty fields by reading the ingredient's own line,
  which is caption text, not invented.
- **Model lumps a comma list into one ingredient.** The validator splits it when every
  piece starts with an amount ("3 cloves garlic, minced" stays whole).
- **Degenerate loop:** one response repeated "cups of sugar, cup of sugars, …" inside
  `unit` until it timed out. Fixed by `maxLength` on schema fields (Ollama's grammar
  enforces it), `num_predict` 2048 and `repeat_penalty` 1.1.
- **Injection:** with prompt-1 the model called the injected caption "not a recipe".
  prompt-3 says text addressed to an AI isn't part of the recipe, so it extracts the
  recipe and ignores the injection.
- **Non-recipes:** the model said `is_recipe=false` but put a chatter sentence in
  `steps`. "Not a recipe" with no ingredients is now treated as no recipe.

Remaining misses are small: ingredients mentioned only inside a step (cheddar in a chili
paragraph), and step splitting in paragraph-style captions. The review screen covers
both.

## 2026-10-15: prompt-5 (every schema field required)

A real reel failed in the app (ReciMe struggled with it too): three sections (fries,
chicken, sauce), where the first section has its own instructions. Qwen returned only the
fries section. It is now case `sections_with_own_steps`.

**Cause, from the raw output:** the schema sent to Ollama required only `raw_text`, and
Ollama's grammar generates exactly what the schema allows. Qwen skipped `name`, tried to
put "medium russet potatoes, cut into thin fries" in `unit`, got cut at the 20-character
cap ("medium russet potat0"), lost its place, and closed the JSON. A prompt rule about
multi-section captions changed nothing (2/9); requiring every key fixed it.

Same 14 captions, same Mac, back to back
(`python -m eval.run_eval ollama`):

| | prompt-4 | prompt-5 |
|---|---|---|
| Recipe vs non-recipe correct | 14/14 | 14/14 |
| Expected ingredients found | 54/69 | **60/69** |
| Quantity exact (of found) | 53/54 | **60/60** |
| Step count matches | 9/14 | **11/14** |
| Rows not matching the caption | 1 | **0** |
| Amounts/units the validator stripped | 1 | 1 |
| Injected words in an unflagged row | 0 | 0 |
| The failing reel | 2/9 | **7/9** |
| Median / max latency | 31.5 s / 75 s | 28.1 s / 81 s |

Still missed on the reel: the chives and the last two steps, which come after a cookbook
ad in the caption, and a repeated "Avocado oil, spray" line. The review screen's "Found N
ingredients" summary makes a short result visible. The new case also brings the max
latency to 81 s, under the 120 s timeout.

`--case ID` and `--repeat N` run single cases, e.g.
`python -m eval.run_eval ollama --case sections_with_own_steps --repeat 3`.

