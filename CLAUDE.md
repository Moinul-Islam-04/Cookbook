# Instructions for Claude Code in this repo

Read `docs/BRIEF.md` (the product brief and rules), `README.md` (current status and
setup) and `docs/DECISIONS.md` before changing anything.

## Ground rules (from the brief)

- Work in small vertical slices. State the change and its acceptance check before
  editing.
- Don't claim success you haven't verified. Say exactly which checks ran and which
  couldn't.
- Backend changes: run `cd backend && pytest -q` against PostgreSQL (never SQLite). Any
  schema change gets a hand-written Alembic migration, and `alembic check` must stay
  clean (the test suite runs it).
- iOS changes: build with `xcodebuild` and exercise the flow in the Simulator.
- Never invent recipe quantities, steps or Instagram/API capabilities. Never scrape
  Instagram.
- No Redis, API gateway, Kafka, Elasticsearch, NoSQL or read replicas.
- Ask the user before choices that change cost, privacy, external account access or
  scope. Record routine choices in `docs/DECISIONS.md`.
- Update the README's status section after each passing slice.

## Current next task

See "Next smallest task" in `README.md`. The iOS app is in `ios/` (build with
`xcodebuild -project ios/Cookbook.xcodeproj -scheme Cookbook`).

API contract: run the backend and open http://127.0.0.1:8000/docs, or read
`backend/app/schemas.py`. Key points:

- Ingredients and steps are ordered arrays.
- `quantity`/`unit` may be null. `raw_text` is always present on responses.
- PATCH needs `version`. A 409 `stale_version` must keep the user's unsaved edits.
- Errors use one envelope: `code`, `message`, `field_errors[{field, message}]`,
  `retryable`, `request_id`.

## AWS (deployment branch)

- AWS CLI profile `cookbook`. The project uses the new AWS experience: say "project",
  not "account". Create every regional resource in `us-east-2`; the project can't use
  other Regions (the Agent Toolkit's own calls use `us-east-1`).
- The project has a $20 spend limit that pauses it when exceeded. If calls that worked
  start returning Access Denied, check AWS Settings → Billing before debugging.
- The $20 is a one-time budget. State the cost of anything before creating it, and ask
  before creating paid resources. Offer to clean up resources that aren't needed.
