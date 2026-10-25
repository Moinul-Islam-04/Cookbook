# Data flow: from a food post to a saved recipe

How an Instagram or TikTok post becomes a recipe: who calls what, the type at each
boundary, and where each function lives. Paths are relative to the repo root; backend
paths are under `backend/`. Every function named here is checked to exist by
`backend/tests/test_data_flow_doc.py`.

## The pipeline at a glance

```
 PHONE (iOS, SwiftUI)                 SERVER (FastAPI, backend/app)                        POSTGRESQL
 ────────────────────                 ─────────────────────────────                        ──────────
 Stage 1  FETCH  (per platform, on the device; the server never contacts IG/TikTok)
   in-app browser / paste / screenshots
          │
          │ POST /v1/import-drafts   ImportDraftCreate (JSON)
          ▼
                         routers/import_drafts.create_draft
                           ├─ routers/recipes._parse_source(url)  → SourcePost | None   (source_urls.py)
 Stage 2  NORMALIZE        ├─ ingest.normalize(body, source)      → RawPost             (per platform)
                           ├─ check_import_limits(...)            → 429 if over
 Stage 3  EXTRACT          ├─ extraction.run_extraction(extractor, raw_post, timeout)
                           │     extractor.extract(raw_post)      → str (JSON)          (Claude Haiku 5.5)
 Stage 4  VALIDATE         │     validate_extraction(json, post)  → DraftContent        (retry once if malformed)
                           ├─ duplicate_post warning (same post already saved?)
                           └─ INSERT raw_posts + import_drafts ──────────────────────▶ raw_posts, import_drafts
          ◀──────────────  ImportDraftOut (JSON)
   review screen: user fixes flagged rows
          │ PATCH /v1/import-drafts/{id}  ImportDraftPatch (version-checked)  ─────────▶ import_drafts.content
          │
 Stage 5  SAVE
          │ POST /v1/recipes {draft_id, …}  RecipeCreate
          ▼
                         routers/recipes.create_recipe
                           ├─ owned_draft(lock) + reject_if_saved
                           ├─ _reject_duplicate (409 unless allow_duplicate)
                           └─ INSERT recipe + ingredients + steps, mark draft saved ──▶ recipes, recipe_ingredients,
          ◀──────────────  RecipeOut (JSON)                                              recipe_steps
```

Only stages 1 and 2 know about platforms. From `RawPost` on, Instagram and TikTok take
exactly the same path.

## Stage by stage

| Stage | Where | Called by | Input type | Output type |
|---|---|---|---|---|
| 1. Fetch | iOS: `ios/Cookbook/Features/InstagramImport/InstagramPageText.swift`, `ios/Cookbook/Features/Import/ImportCaptionView.swift` → `APIClient.createDraft` | the user's tap | a post on screen | `ImportDraftCreate` JSON |
| Route | `app/routers/import_drafts.py` · `create_draft` | FastAPI | `ImportDraftCreate` (`app/schemas.py`) | `ImportDraftOut` |
| Link identity | `app/source_urls.py` · `parse_source_url` (via `app/routers/recipes.py` · `_parse_source`, which turns errors into a 422) | `create_draft` | `str` URL | `SourcePost` (platform, post_id, kind, author_handle, `post_key`, `canonical_url`) |
| 2. Normalize | `app/ingest/__init__.py` · `normalize` → `app/ingest/instagram.py` · `normalize_instagram`, `app/ingest/tiktok.py` · `normalize_tiktok`, `app/ingest/raw_post.py` · `normalize_pasted` | `create_draft` | `ImportDraftCreate`, `SourcePost \| None` | `RawPost` (`app/ingest/raw_post.py`) |
| 3. Extract | `app/extraction/__init__.py` · `run_extraction` → `extractor.extract` (`app/extraction/anthropic.py` · `AnthropicExtractor`, or `app/extraction/fake.py` · `RuleBasedExtractor` / `FakeExtractor`) | `create_draft` | `RawPost` | `str`: JSON shaped like `ExtractionOutput` (`app/extraction/base.py`) |
| Prompt input | `app/extraction/source.py` · `render_post` | `AnthropicExtractor.extract` | `RawPost` | `<caption>…</caption><transcript>…</transcript><comments>…</comments>` |
| 4. Validate | `app/extraction/validate.py` · `validate_extraction` | `run_extraction` | `str` JSON, `RawPost` | `DraftContent` (`app/schemas.py`) |
| Store draft | `create_draft` | n/a | `RawPost`, `DraftContent` | rows in `raw_posts` and `import_drafts` (`app/models.py` · `RawPostRow`, `ImportDraft`) |
| Review | `app/routers/import_drafts.py` · `update_draft` | iOS review screen | `ImportDraftPatch` | `ImportDraftOut` |
| 5. Save | `app/routers/recipes.py` · `create_recipe` | iOS Save | `RecipeCreate` (with `draft_id`) | `RecipeOut`; rows in `recipes`, `recipe_ingredients`, `recipe_steps` |
| Cleanup | `app/cleanup.py` · `cleanup` | `python -m app.cleanup` (cron) | n/a | deletes expired drafts, unreferenced `raw_posts`, old idempotency keys |

## The types at each boundary

**`ImportDraftCreate`** (request, `app/schemas.py`). The only thing the device sends.
```
source_text: str (caption, ≤ 10,000)   source_url: str | None
transcript: str | None (≤ 20,000)      top_comments: list[str] (≤ 20 × 2,200)
author_handle: str | None              posted_at: datetime | None
media_urls: list[https URL] (≤ 20, stored, never fetched)
```

**`SourcePost`** (`app/source_urls.py`). A parsed link, made without any network call.
`instagram:<shortcode>` or `tiktok:<numeric id>` is the `post_key` used for duplicate
warnings. Short links (`vm.tiktok.com`, `/t/…`) are rejected, because resolving them
would mean fetching TikTok.

**`RawPost`** (`app/ingest/raw_post.py`, frozen pydantic model). The platform-neutral post.
```
platform: "instagram" | "tiktok" | None    post_id: str | None    url: str | None
author_handle: str | None   caption: str   transcript: str | None
top_comments: list[str]     media_urls: list[str]   posted_at: datetime | None
```
`platform`, `post_id` and `url` are all None for text pasted without a link. The
Instagram normalizer unwraps pasted preview text (`1,234 likes, 5 comments - handle on
May 1, 2026: "…"`) in `unwrap_preview`, keeping the handle and date.

**`ExtractionOutput`** (`app/extraction/base.py`). The ParsedRecipe the model must return.
It's enforced as a strict JSON schema through structured outputs, built by
`_strict_schema`.
```
is_recipe: bool   title: str | None   servings: int | None
ingredients: [RawIngredient{raw_text, name, quantity, unit, note}]
steps: [RawStep{instruction}]
sub_recipes: [SubRecipeOutput{title, ingredients, steps}]   (one level)
source_fields_used: ["caption" | "transcript" | "comments"]   confidence: float 0-1
```

**`DraftContent`** (`app/schemas.py`). The validated, reviewable draft, stored as JSONB in
`import_drafts.content`, with a write-once copy in `import_drafts.extracted_content`.
```
title, warnings[DraftWarning{code, message, field, recipe_id}]
ingredients[IngredientDraft{name, quantity: Decimal, unit, raw_text, note, sub_recipe: int|None,
                            needs_review, review_reasons}]
steps[StepDraft{instruction, sub_recipe, needs_review, review_reasons}]
is_recipe, servings, sub_recipes[SubRecipeDraft{title}], source_fields_used, confidence
```
Sub-recipe rows are kept flat: a row's `sub_recipe` is an index into `sub_recipes`.

**`RecipeCreate` → `RecipeOut`** (`app/schemas.py`). What's saved. `servings` and an
ingredient's `note` are optional. A draft's servings are used when the save omits them.

## What validation guarantees (`app/extraction/validate.py`)

The model is untrusted. "The source" means the caption, transcript and comments joined
together (`app/extraction/source.py` · `fidelity_text`).

| Check | Function | If it fails |
|---|---|---|
| JSON matches `ExtractionOutput` | `_parse_json` | `MalformedOutput` → `run_extraction` retries once (≥ 10 s left), then 502 |
| Ingredient/step text appears in the source | `_in_source` | row flagged `not_in_source` |
| Quantity is written (or spoken) in that ingredient's own text, and positive | `_source_amount`, `parse_amount`, `amounts_in` | quantity removed, `quantity_not_in_source` |
| Unit appears in the line | `_unit_in` | unit removed, `unit_not_in_source` |
| Unit is in the known list | `canonical_unit` (`app/extraction/quantities.py`) | mapped to one spelling, or flagged `unit_unknown` |
| Note comes from the line | `_ingredient` | note removed, `note_not_in_source` |
| Title is stated in the source | `validate_extraction` | cleared + `title_missing` |
| Servings are stated ("serves 4") | `_servings_in` | set to None |
| Confidence | `validate_extraction` | clamped to 0–1; < 0.5 adds `low_confidence` |
| No recipe content | `validate_extraction` | empty lists + `no_recipe_found`, plus `recipe_elsewhere` for "link in bio" |

## Errors on the way (the one error envelope: `code`, `message`, `field_errors`, `retryable`, `request_id`)

| Where | Cause | HTTP / code |
|---|---|---|
| `_parse_source` | unsupported or short link | 422 `invalid_request` (`field_errors[source_url]`) |
| `check_import_limits` | per-user or global limit | 429 `rate_limited` + `Retry-After` |
| `run_extraction` | deadline passed | 504 `extraction_timeout` |
| `run_extraction` | malformed twice | 502 `extraction_failed` |
| `AnthropicExtractor` | network / account / other | 503 `extraction_unreachable` / `extraction_account` / `extraction_unavailable` |
| `update_draft` / `update_recipe` | stale `version` | 409 `stale_version` (the client keeps its edits) |
| `create_recipe` | same post already saved | 409 `duplicate_recipe` (the draft already carried a `duplicate_post` warning) |

Nothing is written before extraction succeeds, so a failed import leaves no rows behind.

## Where the data lives

```
users ──1:N── recipes ──1:N── recipe_ingredients   (position, name, quantity, unit, raw_text, note)
  │             │  └──1:N── recipe_steps          (position, instruction)
  │             │  └──1:N── recipe_images
  │             └──N:1 (SET NULL)── raw_posts ──N:1── users
  └──1:N── import_drafts ──N:1 (SET NULL)── raw_posts
               └──N:1 (SET NULL)── recipes (saved_recipe_id)
```
- `raw_posts` (migration 0007): one snapshot per import, kept so posts can be re-parsed
  when the extractor improves. It's never returned by the API, and is deleted by cleanup
  once no draft or recipe refers to it.
- `recipes.servings`, `recipe_ingredients.note` (migration 0008).
- `recipes.extracted_content` / `extraction_version`: the model's validated output and
  `provider:model:prompt-version`, copied from the draft on save so corrections can be
  measured (`python -m app.corrections`).
- Sub-recipes are not separate recipes in the app (the owner's choice). The many-to-many
  alternative is measured in `backend/lab/`.

## Adding a platform

1. `app/source_urls.py`: hosts, a path regex, a `_<platform>` parser and a `Platform`
   literal value.
2. `app/ingest/<platform>.py` · `normalize_<platform>` and an entry in `NORMALIZERS`.
3. The `raw_posts.platform` check constraint (a migration).
4. Fixtures in `backend/tests/fixtures/posts/`, plus golden eval cases.

Nothing in extraction, validation or saving changes.

## Evals

`backend/evals/` runs the real `run_extraction` over hand-labelled golden posts and
scores the `DraftContent` against the expected ParsedRecipe. See
`backend/evals/golden/README.md` and `backend/evals/RESULTS.md`.
