# Extraction evaluation

`eval/captions.json` holds 12 hand-labelled captions:
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
