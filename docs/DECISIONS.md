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

## 2026-10-14: Local Qwen 2.5 7B via Ollama is the extraction provider (for now)

- **Context:** The owner chose to try a free, local model first, and to fall back to
  Claude Haiku only if it performs badly.
- **Decision:** Use `COOKBOOK_EXTRACTION_PROVIDER=ollama` with `qwen2.5:7b`.
  - The request uses structured output: the JSON schema with per-field `maxLength`,
    temperature 0, `num_predict` 2048 and `repeat_penalty` 1.1.
  - The caption is sent inside `<caption>` delimiters, with the instruction to treat it as
    data. The extraction timeout is 60 s, and the iOS request timeout is 90 s.
  - On the 12-caption evaluation it scored 12/12 recipe detection, 47/50 ingredients,
    46/47 exact quantities and 0 injected words. See `backend/eval/RESULTS.md`.
- **Consequences:**
  - Captions never leave the Mac, and extraction is free.
  - It's slow: 15–40 s per caption on an M2, plus a few seconds the first time the model
    loads.
  - It only works while Ollama is running on the same machine as the API, so it isn't
    deployable to a small cloud server as is.
- **Alternatives:** Claude Haiku 5.5. Likely faster and better on messy prose, but it
  costs money per caption and sends captions to Anthropic. The adapter and evaluation
  are ready for it.
- **Revisit:** If latency hurts real use, if accuracy drops on real captions, or when
  the backend is deployed.

## 2026-10-14: Instagram import reads the caption in an in-app, logged-out browser

- **Context:** The core feature is ReciMe-style "import from an Instagram link". The
  access spike found no permitted API. Meta's oEmbed is for embedding only: its terms
  prohibit "consuming, manipulating, extracting, or persisting" the content, it needs App
  Review, and it documents no caption field. A server that fetches Instagram pages would
  be a scraper, which the brief forbids.
- **Decision:** The *user's device* shows the post in a `WKWebView`, the same way
  ReciMe's flow appears to work:
  - The session is non-persistent: no cookies, and never logged in.
  - The user can start from the clipboard banner, from **+ → Import from Instagram Link**,
    or by pasting a link.
  - When the user taps **Import Recipe**, a script reads text the page already shows: the
    longest `<h1>`, falling back to the quoted caption in `og:description`/`og:title`.
    The script makes no requests of its own.
  - The caption fills the Import Caption screen, the draft starts, and the user reviews
    it before anything is saved.
- **Guardrails:**
  - It runs only when the user taps, on Instagram post and reel links only.
  - The browser stays on Instagram hosts (other links open in Safari).
  - Login walls aren't bypassed. A page with no readable caption falls back to paste or
    screenshot.
  - The backend never contacts Instagram. It only receives text the user then reviews.
- **Risk (to raise with Andrew):** This deviates from the brief, which says "approved API
  calls only". Instagram's terms broadly prohibit automated collection without permission.
  This is user-initiated and one page at a time, but it's a gray area, not a permitted
  API. Instagram can also change its logged-out page at any time. The selectors are
  isolated in `InstagramPageText` and degrade to the paste fallback.
- **Verified:** A real public reel (DF7v5Fxx5Ot) opened logged out behind Instagram's
  "watch in the app" interstitial. The full caption was still read from the page, and the
  draft came back with the correct title and 10 measured ingredients with correct amounts,
  nothing invented. Weak spots, from the model rather than the browser:
  - Steps came back as whole sections.
  - A section heading was listed as an ingredient.
  - Ingredients mentioned only inside sentences were missed.
- **Revisit:** If Instagram blocks logged-out pages, or if Meta offers a permitted
  caption API.

## 2026-10-14: Qwen 2.5 7B is too slow on real captions; extraction timeout raised to 120 s

- **Observed:** The real 1,055-character reel caption took about 61 s on a 16 GB M2 with
  Xcode and the Simulator running (about 70 MB of RAM free), and hit the old 60 s limit.
  Prompt-4 (section headings, ingredients inside sentences, one step per sentence) fixed
  headings on a synthetic multi-section caption (`eval`: 0 headings as ingredients). It
  didn't change Qwen's output on the real caption.
- **Stopgap:** The server timeout is now 120 s and the iOS request timeout 150 s.
- **Open decision:** Keep Qwen (free, private, slow), try a smaller local model, or switch
  to Claude Haiku 5.5 (fast, costs per caption, sends captions to Anthropic) and run
  `eval` on it.

## 2026-10-14: Self-hosted on the owner's Mac, reached over Tailscale

- **Context:** The owner wants the app on their iPhone at no extra cost.
- **Decision:** The backend, PostgreSQL, Ollama and photo storage all run on the owner's
  Mac. The iPhone reaches the Mac over Tailscale (free personal plan): a private,
  encrypted network between the owner's devices, with no public exposure. The API stays
  bound to 127.0.0.1, and `tailscale serve` publishes it to the tailnet over HTTPS.
- **Consequences:** It costs $0 and keeps captions and photos private. The app works only
  while the Mac is awake and online, and backups are our job (a nightly `pg_dump`). The
  stack is cloud-ready (Postgres, S3-compatible storage, configuration through the
  environment), so moving it is a hosting change.
- **Revisit:** When the app needs to work with the laptop off, when there's more than one
  user, or when moving to a paid model API.

## 2026-10-14: Device tokens instead of managed auth (auth_mode=token)

- **Context:** The brief prefers managed auth (verifying signature, issuer, audience and
  expiry). That fits a multi-user service. This is one owner on a self-hosted backend,
  and a provider would add an account, and possibly a cost, for no benefit yet.
- **Decision:**
  - `python -m app.tokens create --name … --server …` issues an opaque random token
    (`ckb_` plus 256 bits) and prints it once, with a pairing code.
  - The server stores only its SHA-256 (`api_tokens`), with an expiry (1 year by
    default), `revoked_at` and `last_used_at`.
  - Every `/v1` request needs `Authorization: Bearer`. Unknown, forged, expired or
    revoked tokens get 401 `unauthenticated`. `/healthz` stays open, for reachability
    checks.
  - iOS stores the token in the Keychain (`AfterFirstUnlockThisDeviceOnly`, never
    synced). The server URL goes in UserDefaults, and is set by pasting the pairing code
    in Settings.
  - `dev` mode (no auth) remains for local tests. Any other mode refuses to start.
- **Verified:** 11 auth tests, covering forged, malformed, expired and revoked tokens, a
  hash-only store, and user B getting 404 on all of user A's recipes and drafts (including
  saving A's draft). Removing the expiry and revocation check fails them. All three iOS
  contract suites pass against a token-mode server. The Simulator was paired through the
  real Settings → Paste flow, and the list loaded.
- **Revisit:** Before a second user or a public deployment. Then use a managed provider
  (Sign in with Apple, Supabase or Clerk), with JWT verification replacing the hash lookup
  in `app/deps.py`.

## 2026-10-14: Photos in S3-compatible storage (MinIO locally), served by signed API URLs

- **Decision:**
  - `app/storage.py` defines a small interface: put, get, delete and list. It has an
    `S3Store` (boto3) and a `MemoryStore` (tests). Locally, MinIO runs on
    **127.0.0.1:9000 only**, with generated credentials in `backend/.env`. Homebrew's
    service would listen on all interfaces with `minioadmin`, so it isn't used. Moving to
    Cloudflare R2 or AWS S3 is a config change.
  - Uploads (`POST /v1/recipes/{id}/images`, multipart):
    - The server decodes the file with Pillow and accepts only JPEG, PNG or WebP of at
      most 10 MB and 50 MP. Content-Type and extension aren't trusted, and decompression
      bombs are rejected.
    - It applies the EXIF rotation, then re-encodes to JPEG with **no metadata**, so GPS
      and camera details never reach storage.
    - It stores a 2048 px full image and a 600 px thumbnail under random keys
      (`users/{uid}/recipes/{rid}/{uuid}.jpg`).
    - The order is: process, store the objects, then commit the row. If the commit fails,
      the objects are deleted. There are at most 10 photos per recipe.
  - Reads: the API returns relative URLs, `/v1/image-files/{key}?exp=…&sig=…`, signed
    with HMAC-SHA256 under `COOKBOOK_IMAGE_SIGNING_KEY`. TTL is 10 minutes, with expiry
    rounded to a boundary so URLs stay cacheable. The signature authorizes the read, so
    no bearer token is needed and SwiftUI's `AsyncImage` can load it. The read also
    requires the `recipe_images` row, so **a deleted photo stops loading immediately**,
    even inside its TTL.
  - Deleting a photo or a recipe deletes its objects after commit. Failures, and objects
    left by interrupted uploads, are orphans: `python -m app.cleanup` removes
    unreferenced objects older than 1 hour.
- **Alternatives:** Presigned MinIO URLs, as the brief suggests ("short lived signed read
  URLs"). The phone would then also need to reach MinIO over Tailscale, which means a
  second exposed service and its own TLS. Our own signed endpoint gives the same
  property (expiring, unguessable, nothing public) with one origin. With R2 we could
  switch to presigned redirects.
- **Accepted:** a device that already loaded a photo may show its cached copy for up to
  the TTL after deletion (`Cache-Control: private`). The server refuses fresh reads.
- **Verified:** 18 photo tests, covering validation, GPS stripping, rotation, bombs,
  tampering, expiry, delete-while-in-TTL, recipe delete, ownership, storage outages,
  rollback on the photo limit, orphan cleanup, and token mode. Live checks against
  MinIO, and the Swift client contract (upload, signed load without a token, 404 after
  delete).
- **Also fixed:** tests read `backend/.env`, so the first run uploaded about 30 objects to
  the real MinIO, since cleaned. Tests now use `make_settings()`, which never reads
  `.env`.
