# Cookbook

A personal cookbook for recipes found on Instagram: native SwiftUI iOS app, FastAPI
service, PostgreSQL. Full product brief: [`docs/BRIEF.md`](docs/BRIEF.md).
Engineering decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Status

| Milestone | State |
| --- | --- |
| 0 Runnable baseline | Backend and iOS project done. Instagram access spike not run. |
| 1 Manual recipe persistence | **Done.** Backend tested; create, edit, stale edit and delete walked through on the Simulator (2026-10-15). One gap: no pull to refresh on the empty list. |
| 2 Search and duplicate safeguards | **Done.** Backend tested (94 tests); iOS built and contract-checked; search and the duplicate alert walked through on the Simulator (2026-10-15). |
| 3 Extraction and review | **Done.** Built and first evaluated with local Qwen 2.5 7B via Ollama, behind the adapter; the app now uses Claude Haiku 5.5 (see below). Import Caption, review and the failure path walked through on the Simulator (2026-10-15). |
| 4 Images and authentication | **Done.** Device tokens, photos, and the app running on a real iPhone over Tailscale. |
| 5 Polish and demonstrate | **Done.** XCTest target (47 tests now, live contract tests included), demo script, accessibility pass (Dynamic Type, audit, hands-on VoiceOver on the iPhone). |
| Haiku extraction (optional) | **Done** (merged from `haiku-extraction`). A Claude Haiku 5.5 provider behind the same adapter and validator, evaluated against Qwen: 67/69 vs 60/69 ingredients, median 1.9 s vs 28 s, about $0.0004 per caption. **The app now uses Haiku** (switched 2026-10-15, and the owner checked imports on the iPhone). Since then: clear errors when Claude can't be reached or the key is out of credit, and prompt-6 (a paragraph step is one whole sentence) at effort `medium`, about 3.3 s and $0.0006 per caption. Ollama/Qwen is no longer tuned or evaluated. See `backend/eval/RESULTS.md` and DECISIONS 2026-10-15. |
| UI pass | **Done** (merged from `UI`, checked on the iPhone). Seven fixes from a screen-by-screen review (import progress, app icon, card grid, recipe layout, ingredient emphasis, Settings, review summary). `ios/screenshots.sh` takes before/after screenshots. See DECISIONS 2026-10-15. |

### What works (backend, verified)

- `POST /v1/recipes`: create a manual recipe with a title, ordered ingredient rows and
  ordered steps. Returns 201 and a `Location` header. Recipe and children save in one
  transaction.
- `GET /v1/recipes?limit=&cursor=`: the current user's recipes, newest first,
  cursor-paginated (default 20, max 100).
- `GET /v1/recipes/{id}`: full detail.
- `PATCH /v1/recipes/{id}`: requires `version`. Omitted fields are unchanged. A supplied
  `ingredients` or `steps` array replaces all rows atomically. A stale version gets
  409 `stale_version` with `current_version`.
- `DELETE /v1/recipes/{id}`: 204, and ingredients and steps cascade.
- Incomplete recipes (title only) save fine and report `"missing": ["ingredients", "steps"]`.
- Missing measurements stay `null`. `raw_text` keeps what was written ("salt to taste").
  If it's omitted, the server composes it from quantity, unit and name ("2 tomatoes").
- One error envelope everywhere: `code`, `message`, `field_errors`, `retryable`,
  `request_id`, `details`.
- `GET /healthz` checks the database connection.
- Request logs contain method, path, status, duration and request ID, never bodies.

### Checks run

- `pytest`: **48 passed** at the end of Milestone 1, against PostgreSQL 16.15, five
  consecutive runs (the whole suite is 184 tests as of 2026-10-15). The Milestone 1 tests
  cover:
  - migration down to base and back up, plus `alembic check` (models match migrations)
  - every DB constraint: foreign keys, unique positions, blank text, quantity > 0,
    cascade delete
  - invalid requests save nothing
  - a DB failure partway through a create or update rolls everything back
  - pagination completeness and order
  - patch semantics
  - stale-version and concurrent-edit handling (one writer wins, the other gets 409)
  - another user cannot list, read, edit or delete your recipes
  - data survives an app restart
- The tests were also checked against deliberately broken code: removing the row lock
  fails the concurrency test, and removing the delete-before-insert flush fails the
  reorder test.
- Manual check: created a recipe, killed the real `uvicorn` process, started it again,
  and read the recipe back.

### Not verified / known limitations

- Authentication is a device token per phone (`COOKBOOK_AUTH_MODE=token`). Create one
  with `python -m app.tokens create --name "iPhone" --server <url>` and paste the printed
  pairing code in the app's **Settings** (the gear icon). `dev` mode has no
  authentication and is for local tests only. Single user, self-hosted: see
  `docs/DECISIONS.md`.
- Tested on Linux with Python 3.13 and macOS with Python 3.12 / PostgreSQL 14 (48 passed,
  at Milestone 1). Python 3.11+ is required.
- Quantities allow up to 3 decimal places (e.g. 0.333). The client should round
  fractions like 1/3.

### iOS (Milestone 1 screens)

`ios/Cookbook.xcodeproj`, iOS 17+, SwiftUI, URLSession, no third-party packages.

- Recipe list: a grid of photo cards (newest first, loads more pages on scroll, pull to
  refresh), with loading, empty and error-with-retry states.
- Recipe detail: ingredients shown with their `raw_text`, numbered steps, notes.
- Create/edit form: ingredient rows (quantity, unit, name) and steps, add, delete, reorder.
  Quantities accept `2`, `1.5`, `1 1/2`, `1/3` (rounded to 3 places). Inline field errors
  from local validation or the server's 422. Save is disabled while saving, and a failed
  save keeps the form as typed. Cancel/swipe-down asks before discarding edits.
- Edit sends only changed fields. A 409 `stale_version` keeps your edits and offers "Save
  My Version" or "Discard Mine and Reload".
- Delete asks for confirmation (long-press a card in the list, or ··· → Delete Recipe on
  the recipe screen). The card is removed only after the server returns 204.
- Errors show the server's message plus its request ID.

Checks run:

- `xcodebuild` for the iPhone 18 Pro Simulator (iOS 27): 0 errors, 0 warnings.
- The API client, models and form logic were compiled with `swiftc` into a harness and
  run against the live server: 33 checks passed. They cover:
  - create, read, list, PATCH and delete
  - dates with microseconds, and exact `Decimal` quantities
  - blank rows dropped, and only changed fields sent
  - `raw_text` kept on untouched rows and recomposed on edited ones
  - clearing notes sends `null`
  - 409 `stale_version` with `current_version`, and a 422 field path
  - 404 after delete
  - a closed port reports a transport error
- Simulator launch: the list showed a recipe created through the API, and the error
  state appeared when pointed at a closed port.

Simulator walkthrough (2026-10-15, `CookbookUITests/Walkthrough` on the iPhone Air
Simulator, iOS 27, against a throwaway dev-mode server, with screenshots of each step):
create (a "1 1/2 cups" row keeps its wording, "salt to taste" keeps a null amount), edit,
a stale edit made by a `PATCH` from "another device" (the 409 alert keeps the edits; Save
My Version saves them; Discard Mine and Reload shows the newer copy), and delete from the
recipe screen and from a card's long-press menu. All passed.
Found: pull to refresh does nothing on the empty "No Recipes Yet" screen, so a recipe
added elsewhere doesn't appear until the app is relaunched (likely because the empty
state isn't in a scroll view, so `.refreshable` has nothing to pull). Pull to refresh on
a non-empty grid wasn't part of this walkthrough.
Dynamic Type, VoiceOver and a physical device were checked later (Milestone 5). Not
checked: an iOS 17/18 runtime.

**Tests:** the `CookbookTests` XCTest target (⌘U in Xcode, or `ios/run-tests.sh`):
- 37 offline unit tests: quantity parsing, form → request rules, ingredient emphasis,
  Instagram link and caption parsing, pairing codes, and `APIClient` headers, decoding
  and error mapping against a stubbed `URLSession`.
- 10 live contract tests (`LiveContractTests`) that run the real client against the real
  server, ported from the earlier `swiftc` harness. They skip unless a token is set:
  `TOKEN=ckb_... ios/run-tests.sh` (in Xcode: Edit Scheme → Test → Arguments →
  `COOKBOOK_TEST_TOKEN`).

**UI tests:** the `CookbookUITests` target, run with the `Screenshots` scheme:
- `ScreenshotTour` screenshots every main screen against the live server
  (`ios/screenshots.sh`).
- `Walkthrough` taps through the Milestone 1–3 flows and asserts what it sees. It deletes
  every recipe on its server, so point it only at a throwaway dev-mode backend (the file's
  header has the command).

Run: start the backend (below), open `ios/Cookbook.xcodeproj`, pick an iPhone Simulator, ⌘R.
Set `COOKBOOK_API_URL` in the scheme's environment to use a different server.

### Milestone 2: search, source links, duplicates, safe retries

- `GET /v1/recipes?q=` matches title or any ingredient name, case-insensitive. Each
  recipe appears once. Cursors are bound to their search.
- `source_url` on create and PATCH accepts Instagram post and reel links only. It's
  normalized to the shortcode and never fetched. Other links get a 422 on `source_url`.
- Saving a post you already saved returns 409 `duplicate_recipe` with the existing
  recipe's ID and title. `allow_duplicate: true` saves a deliberate copy.
- `Idempotency-Key` header on `POST /v1/recipes`. A retry with the same body returns
  the original recipe, and the same key with a different body returns 409.
- iOS:
  - a search bar (300 ms debounce, stale requests cancelled, an empty-results state)
  - a "Source" link field in the editor and "View on Instagram" on the detail screen
  - an "Already in your cookbook" alert with Open Existing / Save Anyway / Keep Editing
  - creates send an idempotency key
- Fixed from Milestone 1: fractions keep their wording. "1/3 cup lemon juice" stays as
  typed, while `quantity` is still stored as 0.333.

Checks run:

- `pytest`: 94 passed, three consecutive runs. The new tests cover:
  - URL normalization and rejection (hosts, credentials, ports, paths, length)
  - search: title, ingredient, case, once per recipe, wildcard escaping, owner scoping,
    pagination, and the cursor tied to its search
  - duplicates, including a PATCH to the same link and 4 simultaneous saves (one 201,
    three 409s)
  - idempotency: replay, a different body, keys per user, replay after delete, and 3
    concurrent requests with one key
- Removing the owner-row lock makes both concurrency tests fail (checked by hand).
- iOS: `xcodebuild` with 0 warnings. The real client code was compiled into a harness
  and run against the live server: 18 Milestone 2 checks and the 33 Milestone 1 checks
  all passed.
- Simulator: the app launches and shows the search bar and list.

Simulator walkthrough (2026-10-15, same test): a title search ("tart"), an ingredient-only
search in capitals ("OLIVE" finds Tomato pasta), the empty-results state, and the
"Already in your cookbook" alert, which names the existing recipe. Keep Editing keeps the
form, Save Anyway saves a copy, and Open Existing closes the editor and opens the saved
recipe without saving anything. All passed.

### Milestone 3: paste a caption → draft → review → save

- `POST /v1/import-drafts` takes `{source_text, source_url?}` and returns a draft: title,
  ingredients and steps, each row with `needs_review` and reasons, plus warnings.
  `GET`/`PATCH /v1/import-drafts/{id}` read and save corrections. Drafts expire after
  24 hours and don't appear in the cookbook or search.
- Extraction runs through `app/extraction` and is configured with
  `COOKBOOK_EXTRACTION_PROVIDER`:
  - `anthropic` (**what the app uses**) is Claude Haiku 5.5 over the API
    (`COOKBOOK_ANTHROPIC_API_KEY`), prompt-6 at effort `medium`. It takes about 3 s per
    caption and costs about $0.0006 each, but captions are sent to Anthropic. If the API
    can't be reached or the key is out of credit, the import shows a clear error and
    "Enter Manually Instead" (no fallback model).
  - `ollama` uses a local `qwen2.5:7b`. Captions stay on the Mac and it's free, but it
    takes about 20–80 s per caption. The owner has stopped tuning and evaluating it; it's
    kept as a one-line switch back.
  - `fake` (the code default when unset, and what the tests use) is a rule-based reader
    for neat layouts, with no model at all.
  Results are in `backend/eval/RESULTS.md`; rerun them with `python -m eval.run_eval
  anthropic --repeat 3` (or `fake`, `ollama`).
- The server checks every draft against the caption. Invented amounts and units are
  removed, text that isn't in the caption is flagged, and a non-recipe gets "No usable
  recipe found". See `docs/DECISIONS.md`.
- `POST /v1/recipes` with `draft_id` saves the reviewed recipe and marks the draft saved,
  once. It requires at least one ingredient and one step.
- **Instagram links:**
  - Copy a reel or post link and open the app, then tap **Import** on the banner.
    **+ → Import from Instagram Link** also works.
  - The post opens in a logged-out in-app browser. Tap **Import Recipe** to read the
    caption off the page and start a draft.
  - The server never contacts Instagram. See `docs/DECISIONS.md` for the guardrails and
    the terms-of-service gray area.
- iOS: **+ → Import Caption**. Paste the caption and optional link, then tap Read Recipe.
  The review screen shows the original caption, warnings and orange flags on unmatched
  rows; edit and save. If reading fails, "Enter Manually Instead" keeps the caption in
  Notes.
- Run `cd backend && .venv/bin/python -m app.cleanup` to delete expired drafts and old
  idempotency keys. It isn't scheduled yet.

Checks run:

- `pytest`: 127 passed, three consecutive runs. The tests include the brief's fixture
  list:
  - missing amounts, mixed and Unicode fractions, "to taste"
  - non-recipes and contradictory captions
  - prompt injection, malformed JSON, provider timeouts and errors
  - draft lifecycle: patch, expiry (410), owner scoping, save-once, simultaneous saves,
    rollback, cleanup
- Mutation checks: removing the double-save guard, or the quantity-in-caption check,
  fails the tests.
- iOS: `xcodebuild` with 0 warnings. The real client code ran against the live server:
  25 Milestone 3 checks passed (draft, persisted corrections, save, replay, save-once,
  duplicate warning, non-recipe, bad link), and the Milestone 1 and 2 checks still pass.

- Qwen evaluation at the time: 12/12 recipe detection, 47/50 ingredients, 46/47 exact
  quantities, 0 injected words, 0 errors. The latest (Haiku, prompt-6, 14 captions × 3
  runs): 42/42 recipe detection, 202/207 ingredients, 0 rows not matching the caption,
  median 3.3 s (`backend/eval/RESULTS.md`).

Simulator walkthrough (2026-10-15, same test, `fake` extractor; no Claude calls): + →
Import Caption, Read Recipe, then the review screen showed "Found 4 ingredients and 2
steps", the title and needs-review warnings, and an orange "Shortened to fit" flag on a
long row. Editing the row cleared the flag ("Nothing flagged"). After adding a title, Save
opened the saved recipe: "½ cup parmesan" kept its wording and "salt to taste" had no
amount. Failure path, against a server whose extractor was down: the error and request ID
appear, the caption and link stay, and Enter Manually Instead opens a new recipe with the
caption in Notes and the link kept. It saves. All passed.
Noticed: after the flagged row is fixed and a title typed, the server's "Give this recipe
a title" and "1 item(s) didn't match" warnings stay on screen next to "Nothing flagged".
The "not found in the caption" flag (which needs a real model) wasn't produced here.

### Photos

On a recipe, tap **Add Photo**. The photo is resized and converted to JPEG on the phone,
then validated, stripped of metadata (including GPS), stored in MinIO, and shown through
short-lived signed URLs. Long-press a photo to delete it. MinIO runs on 127.0.0.1 only:

```bash
brew install minio
# credentials come from backend/.env (COOKBOOK_S3_ACCESS_KEY / COOKBOOK_S3_SECRET_KEY)
cd backend && set -a && . ./.env && set +a && \
  MINIO_ROOT_USER=$COOKBOOK_S3_ACCESS_KEY MINIO_ROOT_PASSWORD=$COOKBOOK_S3_SECRET_KEY MINIO_BROWSER=off \
  minio server --address 127.0.0.1:9000 "$HOME/Library/Application Support/Cookbook/minio"
```

## Running it on your Mac (self-hosted)

`ops/install-services.sh` installs launchd agents, so the backend runs whenever you're
logged in:
- **minio**: photo storage on 127.0.0.1:9000.
- **api**: runs migrations, then FastAPI on 127.0.0.1:8000.
- **backup**: `pg_dump` nightly at 03:30 to `~/Library/Application Support/Cookbook/backups`,
  keeping 14 days.
- **cleanup**: hourly.

PostgreSQL is a Homebrew service (so is Ollama, if you switch back to it). Logs are in `~/Library/Logs/Cookbook/`.
`ops/uninstall-services.sh` removes the agents and keeps the data. After pulling new
backend code, run `launchctl kickstart -k gui/$(id -u)/com.cookbook.api` to restart the API.

### Your iPhone

1. Install Tailscale on the Mac and the iPhone with the same account. In the admin
   console, turn on MagicDNS and HTTPS certificates.
2. Publish the API to your tailnet only, over HTTPS:
   `tailscale serve --bg --https=443 http://127.0.0.1:8000`
   It's then at `https://<mac-name>.<tailnet>.ts.net`, and the setting survives restarts.
3. Create a token for the phone and copy its pairing code:
   `cd backend && .venv/bin/python -m app.tokens create --name "iPhone" --server https://<mac-name>.<tailnet>.ts.net`
   Only a hash is stored, so a lost code means creating a new token (and revoking the old
   one with `app.tokens revoke <id>`).
4. In Xcode, under Signing & Capabilities, choose your Personal Team and a unique bundle
   ID. Select the iPhone and press ⌘R. A free team's install lasts 7 days.
5. In the app, tap the gear icon, then **Paste** the pairing code (Universal Clipboard).
   Settings should show **Connected**.

## Local setup (macOS)

```bash
# PostgreSQL (or use Postgres.app)
brew install postgresql@16 && brew services start postgresql@16
createdb cookbook && createdb cookbook_test

cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env            # defaults use your macOS user over localhost

alembic upgrade head            # apply migrations
pytest -q                       # expect 184 passed
uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

`.env.example` starts with the rule-based `fake` extractor. To import with Claude Haiku as
the app does, set `COOKBOOK_EXTRACTION_PROVIDER=anthropic` and `COOKBOOK_ANTHROPIC_API_KEY`
in `.env` (captions are sent to Anthropic; about $0.0006 each). To use the local model
instead, run `brew install ollama && brew services start ollama && ollama pull qwen2.5:7b`
and set `COOKBOOK_EXTRACTION_PROVIDER=ollama`. That's about 4.7 GB and needs about 8 GB of
free RAM while running.

Open http://127.0.0.1:8000/docs for the interactive API. The iOS Simulator reaches the
Mac's `127.0.0.1` directly, unpaired, when the server runs in `dev` mode. A physical
device pairs with a token and reaches the Mac over Tailscale (see "Your iPhone" above).

If your PostgreSQL role isn't your macOS username, set `COOKBOOK_DATABASE_URL` and
`COOKBOOK_TEST_DATABASE_URL` in `.env`, e.g.
`postgresql+psycopg://postgres@localhost:5432/cookbook`. The test suite **drops and
recreates** the test database's schema, and refuses to run unless the database name
contains `test`.

## Walkthrough: one recipe through the API

These calls assume `dev` mode. In `token` mode, add
`-H 'authorization: Bearer ckb_...'` to each.

```bash
# Create (no amount for pasta or oil: they stay null)
curl -s -X POST localhost:8000/v1/recipes -H 'content-type: application/json' -d '{
  "title": "Tomato pasta",
  "ingredients": [{"name":"pasta"},{"name":"tomatoes","quantity":2},{"name":"olive oil"}],
  "steps": [{"instruction":"Cook pasta."},{"instruction":"Toss with tomatoes and oil."}]}'

curl -s localhost:8000/v1/recipes                       # it's in the list
curl -s -X PATCH localhost:8000/v1/recipes/<id> -H 'content-type: application/json' \
  -d '{"version":1,"title":"Quick tomato pasta"}'       # edit (version becomes 2)
curl -s -X DELETE localhost:8000/v1/recipes/<id> -i     # 204
```

## Layout

```
backend/
  app/            config, models, schemas, errors, auth/deps, tokens (pairing CLI), drafts,
                  images/storage, cleanup, main.py; routers/ (recipes, import_drafts, images)
  app/extraction/ provider adapter (fake, ollama, anthropic), shared prompt, validator
  alembic/        migrations (hand-written, checked against models by the tests)
  eval/           extraction evaluation: captions.json, run_eval.py, RESULTS.md
  tests/          PostgreSQL integration tests
docs/             BRIEF.md, DECISIONS.md, DEMO.md
ops/              launchd services (API, MinIO, backup, cleanup) and their scripts
ios/              Cookbook.xcodeproj
  Cookbook/API/   client, wire models, pairing
  Cookbook/Features/  list, detail, editor, import, Instagram import, photos, settings
  CookbookTests/  unit and live contract tests (run-tests.sh)
  CookbookUITests/    ScreenshotTour (screenshots.sh) and Walkthrough
```

## Next smallest task

The remaining Haiku misses in `backend/eval/RESULTS.md` (prompt-6): one ingredient each in
`paragraph_only` and `multi_section_prose`, and one quantity in `emoji_bullets_unicode`.
Or add real captions that go wrong on the phone to `backend/eval/captions.json`. Or make
pull to refresh work on the empty recipe list (found in the 2026-10-15 walkthrough).
