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

## 2026-10-14: iOS client decodes timestamps with an explicit two-format strategy

- **Context:** The API sends `2026-10-14T19:39:17.693103Z` (microseconds, UTC). Newer
  Foundation accepts that under `JSONDecoder`'s built-in `.iso8601`. Older releases, which
  iOS 17 devices may still have, reject fractional seconds.
- **Decision:** A custom strategy tries `ISO8601FormatStyle` with fractional seconds, then
  without. A decode failure surfaces as `APIError.badResponse`, never as "server unreachable".
- **Alternatives:** Built-in `.iso8601` (OS-dependent). Changing the server to drop
  microseconds (hides the problem in the client).
- **Revisit:** If the minimum iOS rises to a release whose Foundation behaviour is confirmed.

## 2026-10-14: iOS sends only changed fields on PATCH

- **Decision:** The editor diffs the form against what it loaded and sends only changed
  fields. Untouched ingredient rows send back their original `raw_text`; edited rows omit
  it so the server recomposes it ("2 tomatoes" doesn't survive a change to 3). Clearing
  notes sends an explicit `null`.
- **Consequence:** A stale-version 409 offers "save my version" (diff against the latest
  copy and resend) or "discard mine and reload". Unsaved edits are kept either way until
  the user chooses.
- **Revisit:** Milestone 2+ if partial-row edits are needed (today a changed list replaces
  all rows).

## 2026-10-14: No iOS test target yet; contract checked with a compiled harness

- **Context:** Adding an XCTest target means hand-editing `project.pbxproj`.
- **Decision:** The API and form logic are UI-free files. They were compiled with `swiftc`
  alongside a throwaway harness and run against the live server (33 checks). Add a real
  test target from Xcode (File → New → Target → Unit Testing Bundle) and port the checks.
- **Revisit:** Next iOS slice.

## 2026-10-14: Source links are Instagram posts and reels only

- **Context:** Milestone 2 needs a stable post identity for duplicate warnings.
- **Decision:** `source_url` accepts only `instagram.com`, `www.` and `m.` hosts, with
  `/p/`, `/reel/`, `/reels/` or `/tv/` paths, optionally after a username segment.
  The link is normalized to `https://www.instagram.com/{p|reel}/{shortcode}/`, and
  `source_post_key` is `instagram:{shortcode}`. Query strings, fragments, the username
  and `p` vs `reel` are ignored for identity. Shortcode case is kept. Links are only
  parsed, never fetched (`app/source_urls.py` makes no network calls). Anything else
  gets a 422 on `source_url`.
- **Alternatives:** Accepting any URL and only keying Instagram ones. Rejected for now
  because the brief says not to guess identities for unsupported formats. Revisit when
  another source (a website, TikTok) is actually supported.
- **Revisit:** When a second source kind is added.

## 2026-10-14: Duplicate posts warn with 409; creates lock the owner row

- **Decision:** A create (or a PATCH that changes the link) for a post the user already
  saved returns 409 `duplicate_recipe` with `existing_recipe_id` and `existing_title`,
  unless `allow_duplicate` is true. Every create, and every link-changing PATCH, first
  runs `SELECT … FROM users WHERE id = :me FOR UPDATE`. That makes the duplicate check and
  the insert atomic per user. Lock order is always owner, then recipe.
- **Consequence:** One user's creates are serialized. That's fine for a personal cookbook.
- **Checked by:** the "simultaneous saves" and "concurrent same key" tests fail when the
  lock is removed. Tested by hand on 2026-10-14.

## 2026-10-14: Idempotency-Key on POST /v1/recipes, stored in PostgreSQL

- **Decision:** The `idempotency_keys` table has primary key (user_id, key) and stores the
  request's SHA-256 and the 201 response. The same key with the same validated body replays
  the stored response (`Idempotent-Replayed: true`). A different body gets 409
  `idempotency_key_reused`. Failed requests store nothing, so after a duplicate warning,
  "Save Anyway" can reuse the key. Deleting the recipe keeps the key (`SET NULL`), so a
  late retry can't resurrect it. The iOS editor reuses a key only while the body is
  unchanged.
- **Not done:** Expiry. Keys are kept forever. Add a cleanup command (e.g. older than 24
  hours) alongside the draft cleanup in Milestone 3.

## 2026-10-14: Search is ILIKE over title and ingredient names, no index yet

- **Decision:** `q` does a case-insensitive substring match on the title, or (via EXISTS,
  so each recipe appears once) on any ingredient name. `%`, `_` and `\` are escaped. The
  pagination cursor includes a fingerprint of `q`, so it can't continue a different
  search, and the client resets the cursor when the search changes. iOS debounces by
  300 ms and cancels the previous request.
- **Alternatives:** `pg_trgm` GIN indexes, or full-text search. Not needed at personal
  scale. The brief says to improve PostgreSQL search before adding anything else.
- **Revisit:** If searches slow down with a few thousand recipes, add `pg_trgm` indexes
  on `recipes.title` and `recipe_ingredients.name`.

## 2026-10-14: Extraction behind a provider adapter; fake first, model choice open

- **Context:** The brief leaves the AI provider and cost limit open. Choosing one involves
  cost and privacy, so it's the owner's decision. Tests must never depend on a live model.
- **Decision:** A provider implements `extract(source_text) -> str` (raw JSON, shaped like
  `ExtractionOutput`) and a `version` string that's stored on each draft. `run_extraction`
  enforces `COOKBOOK_EXTRACTION_TIMEOUT_S`. The validator handles every provider the same
  way. Today's providers:
  - `RuleBasedExtractor` (`rules-1`) is the development default. It reads header and bullet
    caption layouts, with no model and no network.
  - `FakeExtractor` returns canned responses keyed by caption, for tests.
- **Next:** Add Ollama (Qwen 2.5) and Claude Haiku 5.5 adapters and compare them on the
  same captions, then pick one.
- **Revisit:** After the comparison.

## 2026-10-14: Source fidelity is enforced on the server, after the model

- **Decision:** `app/extraction/validate.py` treats model output as untrusted:
  - A quantity is kept only if that amount appears in the ingredient's own `raw_text`.
  - A unit is kept only if it appears as a whole word.
  - Ingredients and steps whose text isn't in the caption are kept but flagged
    `needs_review`, with reasons.
  - A title that isn't in the caption is cleared, with a `title_missing` warning.
  - A non-recipe gets `no_recipe_found` and empty lists.
  - Malformed output returns 502, a timeout 504, and a provider error 503 with no details.
- **Known limit (tested):** The check proves text came *from the caption*. It can't tell
  whether that text is a legitimate step. Injected instructions quoted word for word
  pass. The defenses for that are the extraction prompt (caption sent as delimited data)
  and the user's review before saving. The app never claims allergy safety or nutrition.
- **Alternatives:** Trusting a well-prompted model. Rejected because the brief forbids
  invented quantities, and this check works whatever model is behind it.

## 2026-10-14: Drafts are a separate table with whole-draft JSONB content

- **Decision:** `import_drafts` holds the caption, the normalized link, the validated
  content as JSONB, `extraction_version`, `version`, `status` (ready/saved),
  `saved_recipe_id` (`SET NULL`) and `expires_at` (24 hours). Drafts never appear in
  recipe lists or search. `POST /v1/recipes` with `draft_id` saves atomically: it locks
  the owner and the draft, requires at least one ingredient and one step, sets
  `source_kind=caption` and `source_text`, and marks the draft saved. An expired draft
  returns 410 `draft_expired`. `python -m app.cleanup` deletes expired drafts and
  idempotency keys older than 24 hours. It isn't scheduled yet.
- **Alternatives:** Normalized draft child tables. Rejected because drafts are short-lived
  and always edited whole.
- **iOS:** The review screen PATCHes corrections before each save attempt (best effort),
  so they survive a failed save or an app restart. Flags clear when a row is edited.
