# Cookbook

A personal cookbook for recipes found on Instagram: native SwiftUI iOS app, FastAPI
service, PostgreSQL. Full product brief: [`docs/BRIEF.md`](docs/BRIEF.md).
Engineering decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Status

| Milestone | State |
| --- | --- |
| 0 Runnable baseline | Backend and iOS project done. Instagram access spike not run. |
| 1 Manual recipe persistence | **Done.** Backend tested; iOS walked through by hand on the Simulator. |
| 2 Search and duplicate safeguards | **Done.** Backend tested (94 tests); iOS built and contract-checked; Simulator walkthrough of search/duplicate alert still to do by hand. |
| 3 Extraction and review | **In progress.** Import flow done with a rule-based/fake extractor (no AI yet). Real model choice pending. |
| 4–5 | Not started. |

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

- `pytest`: **48 passed** against PostgreSQL 16.15, five consecutive runs. The suite
  covers:
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

- No authentication. A fixed dev user owns everything, and the server refuses to start
  in any other auth mode. **Keep it on 127.0.0.1; do not deploy it.**
- Not built yet, each in a later milestone:
  - a real AI extraction provider (Milestone 3: the adapter, drafts and review are done)
  - images (Milestone 4)
- Tested on Linux with Python 3.13 and macOS with Python 3.12 / PostgreSQL 14 (48 passed).
  Python 3.11+ is required.
- Quantities allow up to 3 decimal places (e.g. 0.333). The client should round
  fractions like 1/3.

### iOS (Milestone 1 screens)

`ios/Cookbook.xcodeproj`, iOS 17+, SwiftUI, URLSession, no third-party packages.

- Recipe list (newest first, loads more pages on scroll, pull to refresh), with
  loading, empty and error-with-retry states.
- Recipe detail: ingredients shown with their `raw_text`, numbered steps, notes.
- Create/edit form: ingredient rows (quantity, unit, name) and steps, add, delete, reorder.
  Quantities accept `2`, `1.5`, `1 1/2`, `1/3` (rounded to 3 places). Inline field errors
  from local validation or the server's 422. Save is disabled while saving, and a failed
  save keeps the form as typed. Cancel/swipe-down asks before discarding edits.
- Edit sends only changed fields. A 409 `stale_version` keeps your edits and offers "Save
  My Version" or "Discard Mine and Reload".
- Delete asks for confirmation (from the list swipe or the detail screen). The row is
  removed only after the server returns 204.
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

Not yet checked: tapping through create, edit, stale-edit and delete in the Simulator.
Also not checked: an iOS 17/18 runtime, Dynamic Type, VoiceOver, or a physical device.
The project has no XCTest target yet.

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

Not yet checked by hand: typing a search, the duplicate alert, and Open Existing navigation.

### Milestone 3 (so far): paste a caption → draft → review → save

- `POST /v1/import-drafts` takes `{source_text, source_url?}` and returns a draft: title,
  ingredients and steps, each row with `needs_review` and reasons, plus warnings.
  `GET`/`PATCH /v1/import-drafts/{id}` read and save corrections. Drafts expire after
  24 hours and don't appear in the cookbook or search.
- Extraction runs through `app/extraction` and is configured with
  `COOKBOOK_EXTRACTION_PROVIDER` (only `fake` today). The default is a rule-based reader
  for typical captions (an "Ingredients" header, bullet or numbered lines), with no model,
  no network and no cost. **No AI is involved yet.**
- The server checks every draft against the caption. Invented amounts and units are
  removed, text that isn't in the caption is flagged, and a non-recipe gets "No usable
  recipe found". See `docs/DECISIONS.md`.
- `POST /v1/recipes` with `draft_id` saves the reviewed recipe and marks the draft saved,
  once. It requires at least one ingredient and one step.
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

Not yet checked by hand: the Import Caption and review screens in the Simulator.

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
pytest -q                       # expect 48 passed
uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

Open http://127.0.0.1:8000/docs for the interactive API. The iOS Simulator reaches the
Mac's `127.0.0.1` directly. A physical device would need the Mac's LAN IP, which is a
deliberate later step because the API has no auth yet.

If your PostgreSQL role isn't your macOS username, set `COOKBOOK_DATABASE_URL` and
`COOKBOOK_TEST_DATABASE_URL` in `.env`, e.g.
`postgresql+psycopg://postgres@localhost:5432/cookbook`. The test suite **drops and
recreates** the test database's schema, and refuses to run unless the database name
contains `test`.

## Walkthrough: one recipe through the API

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
  app/            config, models, schemas, errors, deps, routers/recipes.py, main.py
  alembic/        migrations (hand-written, checked against models by the tests)
  tests/          PostgreSQL integration tests
docs/             BRIEF.md, DECISIONS.md
ios/              Cookbook.xcodeproj; Cookbook/API (client, wire models), Cookbook/Features (list, detail, editor)
```

## Next smallest task

Try **+ → Import Caption** in the Simulator with a few real captions. Then add two
extraction providers behind the adapter: local Qwen 2.5 via Ollama, and Claude Haiku 5.5
with `ANTHROPIC_API_KEY` in `backend/.env`. Run both on the same set of captions to
compare fidelity, flags, latency and cost, and record the choice in `docs/DECISIONS.md`.
