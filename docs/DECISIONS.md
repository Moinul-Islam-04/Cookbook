# Decision log

Format: date, context, decision, alternatives, consequence, revisit when. The brief's own
decisions (single FastAPI service, PostgreSQL only, no Redis, Kafka or Elasticsearch,
review before save) stand as written in `BRIEF.md` §7 and aren't repeated here.

## 2026-10-14: First slice is backend manual CRUD only

- **Context:** The build environment had Python and PostgreSQL but no Xcode.
- **Decision:** Ship the backend half of Milestone 1, tested against real PostgreSQL,
  and build the SwiftUI client on a Mac where it can be compiled and run.
- **Alternatives:** Writing Swift code that couldn't be compiled. Rejected, because the
  brief forbids claiming unverified success.
- **Revisit:** n/a.

## 2026-10-14: Minimum iOS 17, app name "Cookbook"

- **Context:** The brief leaves both open.
- **Decision:** iOS 17 allows the Observation framework (`@Observable`) and current
  SwiftUI navigation.
- **Revisit:** If a target user is on iOS 16.

## 2026-10-14: Incomplete manual recipes are allowed

- **Context:** The brief's §1 says to support incomplete recipes with visible missing
  information. §3 requires an ingredient and a step for a *reviewed import* save.
- **Decision:** For manual recipes, only the title is required. The API reports
  `missing: ["ingredients", "steps"]` so the UI can show what's absent. The stricter
  import-save rule will apply on the draft-save path in Milestone 3.
- **Revisit:** If incomplete recipes clutter the cookbook in practice.

## 2026-10-14: Positions come from array order

- **Decision:** Clients send ordered `ingredients` and `steps` arrays. The server assigns
  positions 0..n-1. `UNIQUE(recipe_id, position)` and `position >= 0` remain in the
  database as a backstop.
- **Consequence:** Clients can't send duplicate or gapped positions. Reordering is just
  sending a reordered array.

## 2026-10-14: PATCH replaces child arrays wholesale under a row lock

- **Decision:**
  - `SELECT … FOR UPDATE` on the recipe, then compare `version`, then delete the old
    child rows (flushed first so positions don't collide), then insert the new ones,
    then increment `version`, all in one transaction.
  - Omitted fields are unchanged. An explicit `null` for title, ingredients or steps
    is a 422.
- **Alternatives:** Per-row diffing, which is more complex and has no current need.
- **Revisit:** If ingredient rows gain identity other data depends on (e.g. images
  per step, or forks).

## 2026-10-14: Quantity is NUMERIC(10,3) and must be > 0

- **Context:** The brief says to reject negative quantities.
- **Decision:** Zero is also rejected, since a 0 amount is never meaningful. "To taste"
  and unmeasured ingredients use `null` plus `raw_text`. Up to 3 decimal places.
- **Revisit:** If fractions need exact storage (e.g. thirds). An option then is storing
  numerator and denominator.

## 2026-10-14: Newest-first keyset pagination on (created_at, id)

- **Context:** The brief proposes ordering by created_at and id.
- **Decision:** Descending order, because the newest saves are what users look for. The
  cursor is opaque base64 JSON. Index: `(user_id, created_at, id)`, whose leading
  column also serves plain owner lookups, so there's no separate `user_id` index.

## 2026-10-14: Unowned resources return 404, not 403

- **Decision:** Callers can't tell whether another user's recipe ID exists.

## 2026-10-14: Request bodies forbid unknown fields

- **Decision:** `extra="forbid"`. A client sending `user_id` gets a 422. Ownership comes
  only from the server-side identity.

## 2026-10-14: Dev-only identity; the server refuses other auth modes

- **Decision:** A fixed dev user UUID is seeded at startup. Startup fails unless
  `COOKBOOK_AUTH_MODE=dev`, so an unauthenticated build can't be deployed by
  misconfiguration.
- **Revisit:** Milestone 4 (managed auth, token verification).

## 2026-10-14: API sessions run in UTC

- **Decision:** The connection option `timezone=UTC`, so timestamps always serialize as
  `…Z` regardless of the server's local timezone. This was found during manual testing:
  responses came back as `-04:00`.
