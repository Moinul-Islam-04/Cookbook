# Architecture: how a food post gets into the cookbook

One Instagram or TikTok post, traced from the phone to PostgreSQL. File paths are relative
to the repo root. For reference tables (every type, check and error code), see
[DATA_FLOW.md](DATA_FLOW.md).

## The big picture

```
 iPhone (SwiftUI)                         FastAPI (backend/app)                         PostgreSQL
 ─────────────────                        ─────────────────────                         ──────────
 1. Read the post ON THE PHONE
    (in-app browser / paste / OCR)
            │  POST /v1/import-drafts {source_text, source_url?, transcript?, top_comments?, …}
            ▼
                                   2. routers/import_drafts.create_draft
                                      ├─ _parse_source(url)   → SourcePost | None   (Instagram or TikTok)
                                      ├─ ingest.normalize(...) → RawPost             (per platform)
                                      ├─ check_import_limits   (429 if over)
                                      ├─ run_extraction(...)  ── 3. extraction/
                                      │     extractor.extract(RawPost) → raw JSON str      (Claude Haiku)
                                      │     validate_extraction(raw, RawPost) → DraftContent
                                      │     (malformed JSON: retried once)
                                      ├─ duplicate_post warning
                                      └─ INSERT raw_posts + import_drafts ───────────────▶ raw_posts
            ◀── 201 ImportDraftOut (title, servings, ingredients[], steps[],                import_drafts
                                    sub_recipes[], warnings[])
 4. Review screen: user fixes rows
            │  PATCH /v1/import-drafts/{id} {version, ...}   (optional, saves edits)
            │  POST  /v1/recipes {title, ingredients, steps, draft_id, source_url}
            ▼
                                   5. routers/recipes.create_recipe
                                      one transaction: recipe + children +  ──────────▶ recipes
                                      draft.status='saved' + idempotency row             recipe_ingredients
                                                                                         recipe_steps
```

**The key rule:** the server never contacts Instagram or TikTok. Reading the post happens
on the phone (step 1). The server only sees what the device sends. It parses the link but
never fetches it, and it stores media URLs without downloading them.

**Only steps 1 and 2 know which platform a post came from.** From `RawPost` on, Instagram
and TikTok take the same path. Adding a platform means a link parser and a normalizer,
nothing else.

## Step by step

### 1. Getting the post (iOS, on the device)
Three ways in, all ending at `APIClient.createDraft` (`ios/Cookbook/API/APIClient.swift`):
- **Instagram link:** `Features/InstagramImport/InstagramImportFlow.swift` opens the post
  in an in-app browser, and `InstagramPageText.swift` reads the caption from the page (the
  `<h1>`, or the `og:description`/`og:title` meta tags). On a login wall or a video-only
  post, it falls back to asking the user to paste.
- **Paste:** `Features/Import/ImportCaptionView.swift`.
- **Screenshots:** `Features/Import/ScreenshotText.swift` runs on-device OCR, and the user
  checks the text first.
- The share extension (`ios/CookbookShare/`) hands a link into the same flow.

The API also accepts a transcript of the video's audio, top comments (creators often put
the recipe there), the author's handle, the post date and media URLs. The app doesn't send
these yet, and it doesn't open TikTok links yet; both are planned for the next iOS round.
Until then they arrive only through the API.

### 2. The draft endpoint and normalizing (`backend/app/routers/import_drafts.py`, `backend/app/ingest/`)
`create_draft(body: ImportDraftCreate) -> ImportDraftOut`
1. `_parse_source(url)` calls `source_urls.parse_source_url`, which returns a
   `SourcePost(platform, post_id, kind, author_handle)`.
   - Its `post_key` is `instagram:<shortcode>` or `tiktok:<video id>`, used for duplicate
     checks.
   - Unknown hosts are rejected with a 422.
   - TikTok short links (`vm.tiktok.com`, `/t/…`) are rejected too, because resolving
     them would mean fetching TikTok.
2. `ingest.normalize(body, source)` picks the platform's normalizer and returns a
   `RawPost`:
   - `ingest/instagram.py` · `normalize_instagram` unwraps pasted preview text
     (`1,234 likes, 5 comments - handle on May 1, 2026: "…"`) and keeps the handle and
     date.
   - `ingest/tiktok.py` · `normalize_tiktok` takes the handle from the link.
   - `ingest/raw_post.py` · `normalize_pasted` handles text with no link.
3. `check_import_limits` caps imports at 20 per hour and 100 per day per user, and 300 per
   day across everyone, before any money is spent.
4. `run_extraction` (step 3). Provider errors map to 502/503/504 with the standard error
   envelope, and nothing is written to the database.
5. If the same user already saved this `post_key`, a `duplicate_post` warning is added.
6. In one commit:
   - a `raw_posts` row: the post exactly as the device read it, kept so it can be
     re-parsed when extraction improves;
   - an `ImportDraft` row with `content` (editable), `extracted_content` (the model's
     untouched output, kept for measuring corrections), `extraction_version` and
     `expires_at` (24 h).

### 3. Extraction (`backend/app/extraction/`), the "parser"
| File | Role | Types |
|---|---|---|
| `base.py` | The `Extractor` protocol, `extract(post: RawPost) -> str`, and the JSON shape the model must return (the ParsedRecipe). | `ExtractionOutput{is_recipe, title, servings, ingredients[RawIngredient{raw_text, name, quantity, unit, note}], steps[RawStep], sub_recipes[SubRecipeOutput], source_fields_used, confidence}` |
| `source.py` | `render_post` puts the caption, transcript and comments in delimited `<caption>`, `<transcript>` and `<comment>` blocks for the model. `fidelity_text` is the text the validator checks against. | `RawPost -> str` |
| `__init__.py` | `make_extractor(settings)` picks the provider. `run_extraction` adds the deadline, retries malformed output once, then validates. | `RawPost -> DraftContent` |
| `prompt.py` | The system prompt shared by all providers, with `PROMPT_VERSION` (now `prompt-7`). | |
| `anthropic.py` | Claude Haiku 5.5 with structured outputs; bounded retries inside the time budget. | |
| `fake.py` | A free rule-based extractor for development and tests. | |
| `validate.py` | **The source-fidelity gate.** Turns the model's raw JSON into a `DraftContent`. It removes any amount, unit or note not in the post and flags rows that don't match. It also maps units to one spelling, keeps servings only when stated, and clamps confidence. | `DraftContent{title, servings, ingredients[IngredientDraft], steps[StepDraft], sub_recipes[SubRecipeDraft], warnings[DraftWarning], is_recipe, confidence, source_fields_used}` |
| `quantities.py` | Deterministic amount parsing: ½, 1 1/2, ranges, spoken numbers ("two tablespoons"), and canonical units. | |

**The design point:** the LLM is treated as untrusted. Every provider's output goes
through the same validator, so swapping models never weakens the "never invent
quantities" rule. "The post" means everything the model was given (caption, transcript
and comments), so a recipe found in a comment isn't flagged.

**What the extractor handles:**
- a recipe in the caption, the transcript or the comments;
- "recipe at the link in bio" (`is_recipe` true with nothing found, plus a
  `recipe_elsewhere` warning);
- non-recipe food posts such as reviews and mukbangs;
- sub-recipes (a sauce made separately);
- emoji bullets, fractions, and vague amounts ("a splash" gets no quantity).

**Sub-recipes stay inside one recipe** (the owner's choice). Their rows sit in the
draft's `ingredients` and `steps`, tagged with a `sub_recipe` index into
`sub_recipes: [{title}]`.

### 4. Review (iOS)
`Features/RecipeEditor/RecipeEditorView.swift` and `RecipeForm.swift` show the caption
beside editable rows, with `needs_review` rows highlighted.
- Edits can be saved to the draft with PATCH, which requires `version`. A 409
  `stale_version` keeps the user's edits.
- PATCH keeps each row's `note` and `sub_recipe` tag, and rejects a tag pointing at a
  sub-recipe that doesn't exist.

### 5. Save (`backend/app/routers/recipes.py`, `create_recipe`)
In one transaction:
- `_lock_owner` locks the user's row, so two simultaneous saves can't both pass the
  duplicate check.
- The idempotency key is checked: a retry returns the original response.
- The draft is loaded and must be unsaved.
- The duplicate check returns 409 `duplicate_recipe` unless `allow_duplicate` is set.
- It inserts the `Recipe` with `source_kind='caption'`, `servings` (the draft's, if the
  request omits them) and `raw_post_id`, plus `RecipeIngredient` rows (with `note`) and
  `RecipeStep` rows. It marks the draft `saved` and writes the idempotency row.

All of that commits together or not at all.

`python -m app.cleanup`, run hourly by a timer on the server, deletes:
- expired drafts;
- any `raw_posts` row that no draft or recipe refers to anymore;
- old idempotency keys.

## The data model (`backend/app/models.py`)

```
users 1 ──< recipes 1 ──< recipe_ingredients   (recipe_id FK, position, name, quantity?, unit?, raw_text, note?)
  │            │     1 ──< recipe_steps         (recipe_id FK, position, instruction)
  │            │     1 ──< recipe_images        (recipe_id FK, object_key → S3)
  │            │     >── 0..1 raw_posts         (raw_post_id, SET NULL on delete)
  │            └── 0..1 >── import_drafts.saved_recipe_id (SET NULL on delete)
  ├──< import_drafts   (user_id FK; content JSONB; raw_post_id SET NULL; expires_at)
  ├──< raw_posts       (user_id FK; platform?, post_id?, url?, caption, transcript?, top_comments JSONB, …)
  ├──< api_tokens
  └──< idempotency_keys (user_id FK, recipe_id FK SET NULL)
```
- Every relationship is one-to-many, with the FK on the child ("many") side.
- `UNIQUE(recipe_id, position)` keeps ingredients and steps ordered with no duplicates.
- Deleting a recipe cascades to its ingredients, steps and images. Its `raw_posts` row
  is left for cleanup.
- `recipes.servings` (1–1000) and `recipe_ingredients.note` were added in migration 0008;
  `raw_posts` in migration 0007.
- There's still no many-to-many. Ingredients are free-text rows, not a shared catalog
  (the brief defers that).
- Sub-recipes as separate recipes would be the first many-to-many: a
  `recipe_components(parent_recipe_id, child_recipe_id)` join table. That design was
  measured in a separate lab database (`backend/lab/RESULTS.md`). It wasn't worth its
  complexity at this app's size, so sub-recipes stay inside one recipe. The method behind
  that call is in [DATA_MODELING.md](DATA_MODELING.md).

## Evals (`backend/evals/`)
- `golden/` holds 30 hand-labelled posts, one JSON file each:
  `{input: RawPost, expected: ParsedRecipe}`.
  - Each is tagged with categories: caption, transcript only, comments, link in bio, not a
    recipe, sub-recipe, messy formatting, and its platform (Instagram or TikTok).
  - Only one case is a real post so far; the rest are marked `synthetic`.
- `scoring.py` scores the real pipeline's output, through `run_extraction` and the
  validator:
  - `is_recipe` accuracy;
  - title match;
  - ingredient-name precision and recall;
  - exact quantity and unit;
  - steps, scored 1–5 by an LLM judge (`judge.py`, Claude Haiku), with a fuzzy offline
    fallback;
  - sub-recipe count, plus the same metrics on each sub-recipe.
- Run `python -m evals.run anthropic` (about $0.02 a run) or `fake` (free, offline). It:
  - prints a table by category;
  - writes `results/<timestamp>.json`;
  - shows what got better or worse since the last run.
- `RESULTS.md` records the baseline and its misses. The older `backend/eval/` harness is
  kept for its history.
- The loop:
  - Re-run the evals before merging any change to the prompt or model.
  - When a real post parses badly, add it to `golden/`.
