# Cookbook

A personal cookbook for recipes found on Instagram: native SwiftUI iOS app, FastAPI
service, PostgreSQL. Full product brief: [`docs/BRIEF.md`](docs/BRIEF.md).
Engineering decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md).

## Status

| Milestone | State |
| --- | --- |
| 0 Runnable baseline | Backend and iOS project done. Instagram access spike not run. |
| 1 Manual recipe persistence | **Backend done and tested.** SwiftUI screens built; Simulator walkthrough of create/edit/delete still to do by hand. |
| 2–5 | Not started. |

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

- **iOS create/edit/delete not yet exercised by hand in the Simulator.** See "iOS" below
  for what has been checked.
- No authentication. A fixed dev user owns everything, and the server refuses to start
  in any other auth mode. **Keep it on 127.0.0.1; do not deploy it.**
- Not built yet, each in a later milestone:
  - search (`q`), duplicate-post warnings and idempotency keys (Milestone 2)
  - import drafts and AI extraction (Milestone 3)
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

Walk through Milestone 1's exit check on the Simulator by hand. Create a recipe with an
unmeasured ingredient, relaunch the app, edit it, force a stale edit (PATCH from `curl`
while the editor is open), and delete it. Then add an XCTest target and port the
contract checks. Milestone 2 (search, duplicate safeguards) follows.
