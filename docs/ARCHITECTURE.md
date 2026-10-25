# Architecture: how an Instagram recipe gets into the cookbook

One post, traced from the phone to PostgreSQL. File paths are relative to the repo root.

> Describes the pipeline before 2026-10-24. For the current one (RawPost, TikTok,
> ParsedRecipe, `raw_posts`, the `backend/evals/` harness), see [DATA_FLOW.md](DATA_FLOW.md);
> for sub-recipes, [DATA_MODELING.md](DATA_MODELING.md) and `backend/lab/RESULTS.md`.

## The big picture

```
 iPhone (SwiftUI)                         FastAPI (backend/app)                    PostgreSQL
 ─────────────────                        ─────────────────────                    ──────────
 1. Read caption ON THE PHONE
    (in-app browser / paste / OCR)
            │  POST /v1/import-drafts {source_text, source_url?}
            ▼
                                   2. routers/import_drafts.create_draft
                                      ├─ _parse_source(url)  → InstagramPost | None
                                      ├─ check_import_limits  (429 if over)
                                      ├─ run_extraction(...)  ── 3. extraction/
                                      │     extractor.extract(text) → raw JSON str   (Claude Haiku)
                                      │     validate_extraction(raw, text) → DraftContent
                                      ├─ duplicate_post warning
                                      └─ INSERT import_drafts ─────────────────────▶ import_drafts
            ◀── 201 ImportDraftOut (title, ingredients[], steps[], warnings[])
 4. Review screen: user fixes rows
            │  PATCH /v1/import-drafts/{id} {version, ...}   (optional, saves edits)
            │  POST  /v1/recipes {title, ingredients, steps, draft_id, source_url}
            ▼
                                   5. routers/recipes.create_recipe
                                      one transaction: recipe + children +  ─────▶ recipes
                                      draft.status='saved' + idempotency row        recipe_ingredients
                                                                                    recipe_steps
```

**The key rule:** the server never contacts Instagram. Getting the caption happens on the
phone (step 1). The server only ever sees text plus an optional link, and it parses the
link but never fetches it.

## Step by step

### 1. Getting the caption (iOS, on the device)
Three ways in, all ending at `APIClient.createDraft` (`ios/Cookbook/API/APIClient.swift`):
- **Instagram link:** `Features/InstagramImport/InstagramImportFlow.swift` opens the post
  in an in-app browser. `InstagramPageText.swift` reads the caption from the page (the
  `<h1>`, or the `og:description`/`og:title` meta tags). On a login wall or a video-only
  post, it falls back to asking the user to paste.
- **Paste:** `Features/Import/ImportCaptionView.swift`.
- **Screenshots:** `Features/Import/ScreenshotText.swift` runs on-device OCR, and the user
  checks the text first.
- The share extension (`CookbookShare/`) just hands a link into the same flow.

### 2. The draft endpoint (`backend/app/routers/import_drafts.py`)
`create_draft(body: ImportDraftCreate) -> ImportDraftOut`
1. `_parse_source(url)` calls `source_urls.parse_instagram_url`, which returns
   `InstagramPost(shortcode, kind)`. Its `post_key` is `"instagram:<shortcode>"`, used for
   duplicate checks. Unknown hosts are rejected and nothing is fetched.
2. `check_import_limits` caps imports at 20 per hour and 100 per day per user, and 300 per
   day across everyone, before any money is spent.
3. `run_extraction` (step 3). Provider errors map to 502/503/504 with the standard error
   envelope, and nothing is written to the DB.
4. If the same user already saved this `post_key`, a `duplicate_post` warning is added.
5. An `ImportDraft` row is inserted with `content` (editable), `extracted_content` (the
   model's untouched output, kept for measuring corrections), `extraction_version`, and
   `expires_at` (24 h).

### 3. Extraction (`backend/app/extraction/`), the "parser"
| File | Role | Types |
|---|---|---|
| `base.py` | The `Extractor` protocol: `extract(source_text: str) -> str`. Also the JSON shape the model must return. | `ExtractionOutput{is_recipe, title, ingredients[RawIngredient], steps[RawStep]}` |
| `__init__.py` | `make_extractor(settings)` picks the provider. `run_extraction` adds the deadline, then validates. | `str -> DraftContent` |
| `prompt.py` | The system prompt shared by all providers, with `PROMPT_VERSION`. | |
| `anthropic.py` | Claude Haiku with structured outputs; bounded retries inside the time budget. | |
| `fake.py` | Free rule-based extractor for dev and tests. | |
| `validate.py` | **The source-fidelity gate.** Turns the model's raw JSON into a `DraftContent`, removing any amount or unit not written in the caption and flagging rows that don't match it. | `DraftContent{title, ingredients[IngredientDraft], steps[StepDraft], warnings[DraftWarning]}` |
| `quantities.py` | Deterministic amount parsing (½, 1 1/2, ranges). | |

The design point: the LLM is treated as untrusted. Every provider's output goes through the
same validator, so swapping models never weakens the "never invent quantities" rule.

### 4. Review (iOS)
`Features/RecipeEditor/RecipeEditorView.swift` and `RecipeForm.swift` show the caption
beside editable rows, with `needs_review` rows highlighted. Edits can be saved to the
draft with PATCH, which requires `version`; a 409 `stale_version` keeps the user's edits.

### 5. Save (`backend/app/routers/recipes.py`, `create_recipe`)
In one transaction:
- `_lock_owner` locks the user's row, so two simultaneous saves can't both pass the
  duplicate check.
- The idempotency key is checked: a retry returns the original response.
- The draft is loaded and must be unsaved.
- The duplicate check returns 409 unless `allow_duplicate` is set.
- Inserts the `Recipe` with `source_kind='caption'`, plus `RecipeIngredient` and
  `RecipeStep` rows, marks the draft `saved`, and writes the idempotency row.

All of that commits together or not at all.

## The data model (`backend/app/models.py`)

```
users 1 ──< recipes 1 ──< recipe_ingredients   (recipe_id FK, position, name, quantity?, unit?, raw_text)
  │            │     1 ──< recipe_steps         (recipe_id FK, position, instruction)
  │            │     1 ──< recipe_images        (recipe_id FK, object_key → S3)
  │            └── 0..1 >── import_drafts.saved_recipe_id (SET NULL on delete)
  ├──< import_drafts   (user_id FK; content JSONB; expires_at)
  ├──< api_tokens
  └──< idempotency_keys (user_id FK, recipe_id FK SET NULL)
```
- Every relationship is one-to-many, with the FK on the child ("many") side.
- `UNIQUE(recipe_id, position)` keeps ingredients and steps ordered with no duplicates.
- Deleting a recipe cascades to its ingredients, steps, and images.
- There's no many-to-many yet. Ingredients are free-text rows, not a shared `ingredients`
  catalog (the brief defers that). Sub-recipes (Andrew's tzatziki question) would be the
  first one: a `recipe_components(parent_recipe_id, child_recipe_id)` join table.

## Evals (`backend/eval/`)
- `captions.json` has 14 hand-labeled cases, covering formats, non-recipes, a prompt
  injection, and one real reel that failed.
- `run_eval.py` scores any provider **through the real validator**:
  - recipe/non-recipe accuracy
  - ingredient recall
  - quantity exactness
  - step count
  - invented amounts stripped
  - injected words that leaked
  - latency and cost
- `RESULTS.md` logs each run and what changed because of it.
- Run with `python -m eval.run_eval fake`, or `anthropic` (costs about $0.0004 per caption).
- Loop: when a real post parses badly, add it to `captions.json`, change the prompt or
  validator, re-run, and compare.
