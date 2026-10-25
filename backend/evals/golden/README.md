# Golden eval cases

One JSON file per case, named `<id>.json`. `python -m evals.run` (from `backend/`) runs the
real extraction pipeline on each case's `input` and scores the validated draft against
`expected`.

```json
{
  "id": "tiktok_spoken_pasta",
  "categories": ["transcript_only", "messy_formatting"],
  "synthetic": true,
  "notes": "Why this case exists and any labelling judgement calls.",
  "input": {                         // a RawPost (app/ingest/raw_post.py)
    "platform": "tiktok",            // "instagram" | "tiktok" | null for a pasted caption
    "post_id": "7301234567890123456",
    "url": "https://www.tiktok.com/@noodle.nina/video/7301234567890123456",
    "author_handle": "noodle.nina",
    "caption": "...", "transcript": "... or null", "top_comments": ["..."],
    "media_urls": [], "posted_at": null
  },
  "expected": {                      // the spec's ParsedRecipe, labelled by hand
    "is_recipe": true,
    "title": null,                   // only a name the post states
    "servings": null,                // only if the post states it
    "ingredients": [{"raw_text": "two tablespoons of butter", "name": "butter",
                     "quantity": 2, "unit": "tbsp", "note": null}],
    "steps": ["Okay so boil about 200 grams of spaghetti."],
    "sub_recipes": [{"title": "tzatziki", "ingredients": [], "steps": []}]
  },
  "forbidden": ["sugar"]             // optional: injected words that must not survive
}
```

## Categories

`caption`, `transcript_only`, `comments`, `link_in_bio`, `not_a_recipe`, `sub_recipe`,
`messy_formatting`. The runner also groups by platform (`instagram`, `tiktok`, `none`),
taken from `input.platform`. A test (`tests/test_evals.py`) requires at least 3 cases per
category and platform.

## Labelling rules (the same as the extraction prompt, prompt-7)

- Copy, never invent. `raw_text` and every step must appear in the post word for word
  (a test checks this); `name` and `note` must appear in `raw_text`.
- `name` is the ingredient without amount, unit or preparation; preparation goes in
  `note` ("3 cloves garlic, minced" → name `garlic`, note `minced`).
- `quantity` is the number in `raw_text` (`½` → 0.5, "two" → 2); null for ranges ("2-3")
  and vague amounts ("a splash"). `unit` uses the canonical spelling from
  `app/extraction/quantities.py` `UNIT_ALIASES` (`tbsp`, `cup`, `clove`, `g`).
- Ingredients named only inside a step ("toss in cornstarch, salt and pepper") count.
- A part with its own ingredients that's made separately (a sauce, a marinade) is a
  sub-recipe. Sections that share one method list are one recipe.
- A "link in bio" post is `is_recipe: true` with whatever the post itself contains.
  Restaurant reviews, mukbangs and chatter are `is_recipe: false` with empty lists.
- Write the judgement calls in `notes`.

## Adding a real post

All but one case (`sections_with_own_steps`, a real reel) are synthetic, written for the
eval. Real posts are what this set needs most:

1. Copy the caption (and the transcript or creator's comment, if the recipe is there)
   exactly as it appears. Don't fix typos or emoji.
2. Make `<id>.json` with `"synthetic": false`, the post's platform, ID and canonical
   link (`https://www.instagram.com/p/<shortcode>/` or
   `https://www.tiktok.com/@<handle>/video/<id>`), and the categories it fits.
3. Label `expected` by hand with the rules above.
4. Run `pytest tests/test_evals.py` (checks the file), then `python -m evals.run anthropic`
   and look at the case's line and its entry in the results file.

**When a real post parses badly in the app, add it here** before changing the prompt, so
the fix can be measured and doesn't regress later.
