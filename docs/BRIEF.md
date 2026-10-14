# Personal Cookbook iOS App

Project brief for Claude Opus 5.5

Build a native SwiftUI app that turns recipe captions into a personal, searchable cookbook. Use FastAPI and PostgreSQL for the backend, object storage for images, and AI only to prepare editable drafts. A user must review every imported recipe before it becomes a saved recipe.

The first usable version should work with pasted captions and manual recipes even if automatic Instagram access is unavailable. Complete and verify the core save, browse, edit, search, and delete workflows before adding broader import sources or social features.

## Product goal

Reduce the friction of finding a recipe again after seeing it on Instagram. Preserve the original source, ingredients, and ordered instructions in a clean native experience. The app is a personal cookbook first; following friends and adapting recipes are later product directions.

## Decisions already made

- Native SwiftUI iOS client; FastAPI Python service; PostgreSQL relational database.
- Child records hold scalar foreign keys. Users do not store lists of recipe IDs.
- Images live in object/blob storage. PostgreSQL stores image references and metadata.
- RESTful resource routes, title and ingredient search, recipe CRUD, and duplicate Instagram post warnings.
- Caption extraction first, review before save, and no invented quantities or instructions.
- No Redis, API gateway, Kafka, Elasticsearch, NoSQL, or read replicas in the MVP.
## How to use this brief

Treat the scope decisions as requirements and the proposed schema, endpoints, and tooling as a starting design. Claude should inspect the repository, explain the first small implementation slice, then build and test it. Record justified changes rather than blindly following a diagram or generating the whole app at once.

Context: this brief incorporates Andrew’s senior engineering feedback and the user’s stated stack and feature choices. The earlier architecture image at /mnt/data/Init_design.png was unavailable in this workspace, so no layout or infrastructure assumptions were taken from it. iOS minimum version, hosting vendors, AI provider, auth provider, and app name remain implementation choices.


# 1 MVP scope and acceptance

| Area | Required behavior |
| --- | --- |
| Manual recipes | Create, read, edit, and delete recipes with a title, ingredient rows, and ordered steps. Support incomplete recipes with visible missing information. |
| Caption import | Paste a caption with an optional Instagram link; produce a draft, review/edit it, then explicitly save. A link alone may require a fallback. |
| Cookbook and search | Recipe list and detail; case insensitive title or ingredient search; pagination; loading, empty, and error states. |
| Duplicates | Normalize Instagram post identity and warn when the same user already saved that post. Offer to open the existing recipe or save another deliberately. |
| Images | Optional user supplied image, upload validation, storage reference, and placeholder on failure. Never assume Instagram media can be copied. |
| Access | Single user local development can precede auth. Authentication and owner checks are required before any externally accessible multiuser release. |

## Optional within MVP only if the core is complete

Add user editable cuisine, prep time, cook time, servings, and simple tags if they remain cheap to implement. Keep absent values null. Do not infer dietary guarantees, allergens, or nutrition. A share extension and screenshot OCR are useful conveniences, not dependencies for the first release.

## Explicitly later

- Video download, audio transcription, frame analysis, and TikTok import.
- Following friends, public/private sharing, feeds, saving others’ recipes, and forking with attribution.
- AI vegan or high protein modifications, version history, and nutrition estimates.
- Persistent offline caching, offline editing, conflict resolution, and background sync.
- Reusable food catalog and ingredient normalization beyond simple ingredient rows.
- Queues, advanced search services, caching layers, and scaling infrastructure only when measurements justify them.
## Definition of a usable MVP

On an iOS simulator, a user can create a manual recipe and import a pasted caption, correct the draft, save once, find it by an ingredient, edit it, and delete it. Restarting the client does not lose saved server data. Missing quantities stay missing; duplicate links show a warning; failures preserve unsaved draft text. Authenticated release tests prove that one user cannot access another user’s recipes or images.


# 2 Instagram access and import flow

## Feasibility is a separate delivery gate

A public Instagram URL is a source identifier, not a promise that the app can retrieve a usable caption. Meta’s official Instagram APIs focus on professional accounts and authorized operations; they do not establish unrestricted recipe extraction from arbitrary posts. Connecting a cookbook user’s account does not automatically authorize access to every creator’s post. Exact endpoints, account eligibility, permissions, app review, and content reuse conditions must be verified for the intended integration.

First implement pasted caption input. Then conduct a short access spike using a permitted API and actual authorized test content. Document what works, approval requirements, returned fields, rate limits, and failures. Enable automatic caption import only after that spike passes. Restrict acquisition to supported Instagram hosts and approved API calls; never fetch arbitrary user URLs or follow redirects into internal networks. Do not build an undocumented scraper or bypass login, private content restrictions, or platform controls.

## Permitted pathways and fallbacks

- Preferred optional automation: supported Meta API access to content the integration is authorized to retrieve, with documented permission and policy checks.
- Reliable MVP: user pastes a caption they can access, optionally adds the original post URL, and supplies their own recipe image.
- Fallback: user provides a screenshot and manually transcribes text initially. Add OCR later if desired; OCR output remains a reviewable draft.
- oEmbed is an embedding mechanism; do not assume embed HTML grants a structured caption extraction or media copying pathway. A share extension may receive a URL only.
## High level flow

SwiftUI import form → FastAPI draft resource → permitted caption acquisition or user pasted text → bounded AI extraction → server schema validation → editable draft response → user correction and confirmation → one transactional recipe save in PostgreSQL → optional image attachment in object storage.

Manual entry skips the source acquisition and AI steps. Failed automatic retrieval returns a clear “Paste the caption instead” action. The import UI retains the URL and any pasted content. The app does not save a recipe in the background or discard a draft because the source cannot be reached.

## Evidence and limits checked October 14 2026

Meta’s published Instagram API documentation on its official Postman workspace distinguishes professional account integrations and notes consumer account limitations for Facebook Login. This supports treating general URL import as unproven, not promising support for all posts. Meta’s oEmbed page could not be fetched during this review because it returned rate limiting; recheck it before implementation.

Primary references: https://www.postman.com/meta/instagram/documentation/6yqw8pt/instagram-api and https://www.postman.com/meta/workspace/instagram/documentation/23987686-9386f468-7714-490f-9bfc-9442db5c8f00

Implementation verification: https://developers.facebook.com/docs/instagram-platform/ and https://developers.facebook.com/docs/instagram-platform/oembed/


# 3 AI extraction and review contract

## Source faithful extraction

The model extracts information that is present in the supplied caption. It must not complete a recipe from culinary knowledge. Preserve the source text and flag ambiguity. If a caption says “flour” without an amount, store the ingredient with a null quantity and unit. If it says “bake until done,” retain that wording; do not add a temperature or cooking time.

- Use a typed response schema with nullable measurements, ordered ingredient/step arrays, source evidence, and a warnings list. Validate it server side before presenting it.
- Separate original evidence from normalized fields. Keep raw ingredient text such as “half a cup” or “salt to taste” even when a parsed amount is available.
- Treat captions, OCR, URLs, and model output as untrusted data. Embedded instructions must not change extraction rules, invoke tools, or reveal secrets.
- If the content is not a recipe, return a draft with a “No usable recipe found” warning and offer manual entry. Do not invent ingredients to satisfy required fields.
- Keep provider credentials on the backend. Bound source length, output size, timeout, and request rate. Avoid logging full captions or personal content by default.
## Proposed draft payload

RecipeDraft: id, source_url?, source_post_key?, source_kind, source_text, title?, ingredients[], steps[], metadata?, warnings[], extraction_version, expires_at. IngredientDraft: name?, quantity?, unit?, raw_text, source_evidence?, needs_review. StepDraft: position, instruction, source_evidence?, needs_review. The provider adapter should expose this contract independently of any vendor SDK.

Example source: “Tomato pasta: pasta, 2 tomatoes, olive oil. Cook pasta, toss with tomatoes and oil.” Expected draft: pasta quantity null; tomatoes quantity 2 and unit null; olive oil quantity null. Two source backed steps. No invented servings, cooking duration, or grams. Title may come from the explicit source title. Otherwise leave it blank and ask the user to name it.

## Review screen and save rules

- Show the original caption beside or above editable title, ingredients, and ordered steps. Highlight missing or ambiguous measurements without blocking intentionally unmeasured ingredients.
- Allow add/remove/reorder ingredient and step rows; preserve user corrections on validation failure.
- Require a nonempty user confirmed title, at least one named ingredient, and at least one nonempty step for normal recipe save. Permit manual repair of incomplete imports.
- Saving is an explicit user action. Draft records are separate from recipes and do not appear in cookbook search.
- A duplicate warning identifies the existing recipe. A user may deliberately save another copy after confirmation; do not silently merge or overwrite.
## Draft lifecycle

Proposed default: store drafts for 24 hours and show that retention in the UI. Delete expired drafts through a simple scheduled cleanup command. Persist warnings and edits until save or expiry; saving references the draft ID and creates the recipe once. No distributed queue is required for the first caption extraction workflow.


# 4 Relational schema and storage

Use UUID primary keys, UTC timestamps, SQLAlchemy models, and Alembic migrations as a proposed implementation. All foreign keys below are scalar UUID values on the child side. The database remains the source of truth; JSON arrays are acceptable in API payloads, but not as substitutes for relational ownership.

| Table | Core fields and relationships |
| --- | --- |
| users | id PK; auth_subject UNIQUE for real auth; created_at. A fixed dev user may seed local development only. |
| recipes | id PK; user_id FK → users.id; title; notes nullable; source_url nullable; source_post_key nullable; source_kind; source_text nullable; created_at; updated_at; version integer. |
| recipe_ingredients | id PK; recipe_id FK → recipes.id; position; name; quantity NUMERIC nullable; unit nullable; raw_text. UNIQUE(recipe_id, position). |
| recipe_steps | id PK; recipe_id FK → recipes.id; position; instruction. UNIQUE(recipe_id, position). |
| recipe_images | id PK; recipe_id FK → recipes.id; object_key UNIQUE; content_type; byte_size; position; created_at. Optional image rows. |
| import_drafts | id PK; user_id FK → users.id; source identity/text; status; validated draft JSONB; warnings; created_at; expires_at; saved_recipe_id nullable FK → recipes.id. |
| Optional metadata | Nullable cuisine, prep_minutes, cook_minutes, servings on recipes. Add tags and recipe_tags join table only when filtering needs it. |

## Constraints and transactions

Set required fields NOT NULL and reject blank titles/names/instructions. Use nonnegative position values and unique positions per recipe. Reject negative quantities and durations; keep “to taste” as raw text with null numeric fields. Cascade ingredient/step/image metadata deletion with a recipe. Delete draft references safely with SET NULL when a saved recipe is removed. Keep child replacement and recipe updates inside one transaction.

## Search and duplicate indexes

Index recipes.user_id and every child foreign key. Index (user_id, source_post_key) for duplicate checks. Normalize recognized /p/ and /reel/ URLs to the post shortcode, ignoring query tracking and trailing slashes; accept only recognized Instagram hosts. Do not guess identities for unsupported URL formats. Duplicate keys are not unique because deliberate copies are allowed.

Start with owner scoped, parameterized PostgreSQL ILIKE queries over titles and ingredient names, using EXISTS to avoid duplicate recipe rows. Escape wildcard input when matching literally. Use stable pagination. B tree indexes help ownership and exact duplicate checks but do not accelerate leading wildcard ILIKE; measure before adding PostgreSQL pg_trgm indexes or full text search.

## Object storage

Store binary images in a private bucket and save stable object keys, not expiring URLs. Start with bounded backend mediated uploads. Check size, decoded image type, and ownership; use randomized keys and short lived signed read URLs. Handle orphan uploads and failed deletes with a small retryable cleanup task. Recipe deletion must not leave images permanently accessible.


# 5 API and application behavior

Use /v1 noun based routes and JSON contracts generated from FastAPI models. Bind ownership to the verified identity, never a user_id supplied in the request body. A simple SwiftUI feature structure with a URLSession API client is sufficient; split responsibilities without creating a framework for every screen.

| Method and resource | Purpose |
| --- | --- |
| GET /v1/recipes | Owner scoped list; q for title/ingredient search; limit and cursor for pagination. |
| POST /v1/recipes | Validate and save a manual recipe or reviewed draft; return 201 and Location. |
| GET /v1/recipes/{id} | Recipe detail including ingredients, steps, and image references. |
| PATCH /v1/recipes/{id} | Update fields and explicitly supplied child arrays in one transaction; require version. |
| DELETE /v1/recipes/{id} | Delete recipe and child metadata; return 204; schedule blob cleanup. |
| POST /v1/import-drafts | Create draft from pasted text or an enabled permitted source adapter. |
| GET or PATCH /v1/import-drafts/{id} | Read or persist reviewed draft edits for the current owner. |
| POST /v1/recipes/{id}/images | Upload one validated image and attach its metadata; return 201. |
| DELETE /v1/recipes/{id}/images/{image_id} | Detach image and arrange blob cleanup. |

## Precise save semantics

POST /recipes accepts optional draft_id, allow_duplicate, and an Idempotency-Key. Persist idempotency results scoped to the user in PostgreSQL with a request hash; the same key and body return the same result, while changed bodies conflict. Lock the owner’s row during duplicate check and insertion to serialize simultaneous saves. A duplicate returns 409 with the existing recipe ID unless allow_duplicate is explicitly true. Draft save and recipe insertion commit atomically.

For PATCH, omitted fields remain unchanged; explicitly supplied ingredient/step arrays replace those children atomically. Reject stale versions with 409 and keep local edits for resolution. A save failure must never show a success state. Default pagination proposal: 20 recipes, maximum 100, ordered by created_at and id; reset the cursor when the search changes.

## Errors and native UI

Use one documented error envelope: code, message, field_errors, retryable, request_id. Map invalid fields to 422, missing auth to 401, unavailable or unowned resources to 404, duplicates/stale edits to 409, limits to 429, upstream failures to 502/503, and extraction timeouts to 504. Do not expose provider exceptions or tokens.

Show list loading and empty states, searchable cookbook, recipe detail, manual form, import/review form, and destructive delete confirmation. Disable repeated saves, cancel stale search requests, and debounce search modestly. Retry timeouts deliberately, honoring Retry-After where present. An unavailable source offers paste/manual entry; an unavailable AI provider still permits manual recipe creation.


# 6 Incremental implementation milestones

Deliver each milestone as a small verified change. Do not use dates as promises; proceed when the exit check passes. Suggested tools are proposals, not mandates: SwiftUI and URLSession; FastAPI, Pydantic, SQLAlchemy, Alembic, and pytest; PostgreSQL; one object storage adapter.

## Milestone 0 Establish constraints and a runnable baseline

- Inspect repository instructions and existing code. Record app name, minimum iOS target, auth/AI/storage choices, and local setup in README.
- Create minimal iOS and backend projects with configuration examples and no committed secrets. Add PostgreSQL and a first migration.
- Run an Instagram access spike independently. Exit: app and API run locally; migrations apply; supported import pathway or fallback is documented.
## Milestone 1 Finish manual recipe persistence

- Implement schema, CRUD endpoints, child constraints, transactions, and recipe validation before adding AI.
- Build list, detail, manual create/edit, and delete screens with loading and failure states.
- Exit: a manually entered recipe survives restart; edits and deletions persist; invalid children cannot create partial records.
## Milestone 2 Add search and duplicate safeguards

- Implement title/ingredient search, owner scoping, pagination, post URL normalization, duplicate warnings, and idempotent save behavior.
- Exit: ingredient matches return a recipe once; equivalent post URLs warn; retries and simultaneous saves behave as documented.
## Milestone 3 Add extraction and user review

- Implement the typed AI adapter, deterministic test fixtures, persisted draft resource, warning display, and explicit reviewed save.
- Keep caption paste supported regardless of the access spike. Enable automatic acquisition only for verified permitted cases.
- Exit: missing quantities remain null; a nonrecipe does not become a fabricated recipe; user corrections survive failures.
## Milestone 4 Add optional images and authentication

- Attach images through private object storage, with ownership, validation, loading placeholders, and cleanup.
- Prefer managed auth if feasible. Verify token signature, issuer, audience, and expiry on the backend; keep client tokens in Keychain.
- Exit: two test users cannot read or modify each other’s data or blobs. If auth is deferred, keep the app local and single user; do not release an unauthenticated public backend.
## Milestone 5 Polish and demonstrate

- Exercise the full import → review → save → search → edit → delete workflow on the simulator and a physical device if available.
- Add basic request timing/error logs without content payloads, database backup/restore instructions, and deployment configuration.
- Exit: acceptance checks pass, limitations are documented, and a short working demo is ready for Andrew. Add metadata only after this path is sound.

# 7 Verification and engineering decisions

## Meaningful verification checklist

- Database: apply migrations to a fresh PostgreSQL database; check foreign key rejection, cascade behavior, unique positions, and rollback on failed saves. Use PostgreSQL for integration tests rather than relying only on SQLite.
- API: test full CRUD, empty search, case insensitive title/ingredient matches, repeated ingredient matches, pagination, escaping, and invalid fields.
- Ownership: user B cannot list, read, update, delete, save another user’s draft, or attach/read another user’s images; forged or expired tokens fail.
- Duplicates and retries: query/trailing slash URL variants resolve equally; concurrent same-post saves warn; explicit copies succeed; identical idempotent retries create one recipe.
- AI: fixed fixtures cover missing units/amounts, mixed fractions, “to taste,” nonrecipes, contradictory captions, prompt injection text, malformed JSON, and provider timeout. Never assert exact live model wording.
- UI: one useful end to end smoke test covers review and save; manually verify empty/loading/error states, keyboard editing, Dynamic Type, and VoiceOver labels.
- Images and failures: oversized/nonimage uploads fail; interrupted upload leaves no broken permanent attachment; cleanup is retryable; network loss preserves draft input.
## Engineering decision log

| Decision | Reason and revisit condition |
| --- | --- |
| Single FastAPI service | Keep operations simple. Split only when a concrete responsibility or deployment need demands it. |
| PostgreSQL only for app data | Relational ownership and transactions fit the product. Add no NoSQL or read replicas until a measured requirement exists. |
| No Redis or API gateway | Direct authenticated client to service is enough initially. Normal HTTPS hosting/reverse proxy is acceptable; no extra gateway layer is needed. |
| No Kafka or Elasticsearch | Caption processing starts synchronously with a timeout. Add a job resource/worker only if processing latency requires it; improve PostgreSQL search first. |
| Native SwiftUI | Supports the intended iOS experience. Native code alone does not guarantee performance; profile real screens. |
| AI drafts require review | Protect source fidelity. Later adaptations must be explicitly labeled suggestions and saved separately after review. |
| Offline and social deferred | Offline sync needs durable cache and conflict policy; social features need privacy, attribution, and relationship design. |

Maintain a small decision log with date, context, decision, alternatives, consequence, and evidence for reconsideration. Andrew’s advice is to simplify and stay flexible; new tables or dependencies should solve an observed problem rather than anticipate hypothetical scale.


# 8 Instructions for Claude and future work

## Start with this task

Read this brief and all repository instructions. Inspect what exists. Summarize the agreed MVP and identify unresolved choices. Propose the smallest runnable slice for manual recipe CRUD using SwiftUI, FastAPI, and PostgreSQL. Implement that slice with migrations and meaningful validation, run the available checks, and report exactly what works, what failed, and what remains untested. Keep Instagram acquisition behind a source adapter and start with pasted captions.

## Rules for every coding increment

- Explain the intended change and acceptance check before editing. Make a small vertical slice; avoid generating all features in one pass.
- Inspect existing patterns and use actual documentation for dependencies. Pin compatible versions and do not invent SDK methods, API permissions, or provider capabilities.
- Keep API contracts and database migrations explicit. Review child foreign keys, validation, ownership, transactions, and failure paths as part of each change.
- Run backend tests and relevant iOS build/tests. If Xcode, a simulator, credentials, or a provider account is unavailable, say exactly which verification could not run; do not claim success.
- Use mocked AI responses for deterministic tests plus a limited manual live evaluation. Preserve evidence and unknown measurements. Never seed production data with invented extracted values.
- Commit or otherwise present reviewable changes after a passing slice. Update README, setup steps, and the decision log. Stop feature expansion when the MVP acceptance checks pass.
- Ask for a choice when it materially changes cost, privacy, external account access, or scope. Routine implementation details may be chosen and documented.
## Later work should have its own acceptance criteria

Video and TikTok: verify permitted content access first, then add audio/frame extraction with latency, cost, and source fidelity tests. Social features: design visibility, following, sharing authorization, moderation needs, attribution, and copy/fork semantics before adding a feed. A future nullable parent_recipe_id may link forks, but avoid adding unused relationships now.

AI modifications: generate a separate proposal for vegan or higher protein adaptations, preserve the original, label substitutions and uncertainty, and require review. Do not claim allergy safety or precise nutrition from unverified generated content. Offline: define cache retention, offline read scope, queued edits, version conflicts, and sync recovery before implementing it.

## Open decisions to resolve during implementation

Choose the minimum supported iOS version and project structure; auth provider; AI provider and cost limit; image size/retention limits; object storage/hosting vendors; and whether screenshot OCR belongs in the first release. These are not established commitments from the prior conversation. Keep configurable defaults small and record the final choices.

## Final handoff report required from the coding agent

Report implemented behavior, commands/checks run and their outcomes, known limitations, migration and local run steps, and the next smallest task. Include a short walkthrough of a real recipe moving through the app. The deliverable is working, understandable code with verified behavior, not a large untested scaffold.

