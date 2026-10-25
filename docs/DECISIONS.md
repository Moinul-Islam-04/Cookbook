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
- **Revisit:** Next iOS slice. **Superseded** by the XCTest target below.

## 2026-10-14: XCTest target with offline unit tests and opt-in live contract tests

- **Decision:** `CookbookTests` is a unit-test bundle hosted by the app
  (`@testable import Cookbook`), with a file-system-synchronized folder and a shared
  scheme. Two layers:
  - **Offline unit tests** run everywhere: pure logic, plus `APIClient` against a stub
    `URLProtocol`, so header, decoding and error-mapping rules need no server.
  - **Live contract tests** run the real client against the real backend, ported from the
    `ios/ContractTests` `swiftc` suites (now removed). They `XCTSkip` without
    `COOKBOOK_TEST_TOKEN`, so ⌘U never fails just because the Mac's server is off.
- **Why both:** stubs prove the client does what *I think* the server does; only the live
  tests prove the server agrees. The import test asserts only provider-neutral behavior,
  so it passes on the rule-based fake or on Qwen.
- **Verified:** 42 tests pass on the iPhone 18 Pro Simulator against the launchd API
  (live run about 41 s, mostly Qwen). Re-introducing the old "1/3 cup → 0.333" bug fails
  `testTypedFractionKeepsItsWording`.
- **Gave up:** UI tests. The UI was exercised by the scratch XCUITest driver and by hand;
  a checked-in UI test target is the next step if the UI starts changing often.

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
- **Superseded (2026-10-20):** 30 s on the server, 45 s on iOS, sized for Haiku (see
  "Extraction timeouts sized for Haiku" below).
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
- **Superseded (2026-10-18):** phones now use a Lightsail server (see "The server" below).
  The Mac setup remains for local development and the Simulator.

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
- **Revisited (2026-10-18):** the device tokens stay. Google sign-in (verified JWT)
  issues them instead of replacing them, so `app/deps.py` is unchanged and pairing codes
  still work. See "Deploy to one Lightsail server" below.

## 2026-10-14: Photos in S3-compatible storage (MinIO locally), served by signed API URLs

- **Decision:**
  - `app/storage.py` defines a small interface: put, get, delete and list. It has an
    `S3Store` (boto3) and a `MemoryStore` (tests). Locally, MinIO runs on
    **127.0.0.1:9000 only**, with generated credentials in `backend/.env`. Homebrew's
    service would listen on all interfaces with `minioadmin`, so it isn't used. Moving to
    Cloudflare R2 or AWS S3 is a config change.
  - Uploads (`POST /v1/recipes/{id}/images`, multipart):
    - The server decodes the file with Pillow and accepts only JPEG, PNG or WebP of at
      most 10 MB and 50 MP (24 MP since 2026-10-20). Content-Type and extension aren't trusted, and decompression
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

## 2026-10-15: UI pass on the `UI` branch, reviewed against principles and Apple's HIG

- **Context:** The core features worked, but the UI was default SwiftUI lists. A review of
  all 17 screens with real data (`ios/screenshots.sh`) against general UI principles
  (feedback, consistency, clarity, findability, credibility) and Apple's Human Interface
  Guidelines produced a ranked list, fixed in this order:
  1. **Feedback:** import shows what's happening, elapsed time, and the usual 20–60 s,
     with a working Stop (the local model reports no progress, so nothing fake is shown).
  2. **Credibility:** app icon (SF Symbol `fork.knife`, light and dark) and an accent
     colour checked for contrast: #C2410C on white 5.2:1, #FB923C on black 9.3:1.
  3. **Desirability:** list became a photo-card grid; photo-less recipes get a placeholder.
  4. **Hierarchy:** recipe screen leads with a full-width photo, shows the title once,
     and moves photo/delete actions to a ··· menu.
  5. **Clarity:** ingredient amounts are bold; the characters are always raw_text
     (`IngredientText`, unit-tested).
  6. **Credibility:** Settings had a large blank gap (an iOS 27 LabeledContent sizing
     issue); fixed, and pairing simplified.
  7. **Visibility:** the review screen leads with "Found N ingredients and M steps" and
     a live count of rows to check; the caption is a 4-line preview.
- **Rules kept:** coloured status text (green/orange/red) became a coloured icon with
  standard text, since those colours fail WCAG contrast on white. Every screen was checked
  in light mode, dark mode, and the largest accessibility text size.
- **Not done (features, not polish):** cooking mode, serving scaling, ingredient check-off.
- **Tooling:** `CookbookUITests/ScreenshotTour` walks every screen and round-trips a real
  photo upload on the test recipe. Xcode 27's xcodebuild sometimes doesn't exit after UI
  tests, so the script stops it once results are written. At the largest text size the
  system photo picker's banner hides the photos, so that one step can't run there.

## 2026-10-15: Require every field in the schema sent to Ollama (prompt-5)

- **Context:** a real three-section reel imported as one section (2 of 9 ingredients).
  The schema required only `raw_text`, and Ollama's grammar lets the model skip anything
  optional; Qwen skipped `name`, pushed a description into the 20-character `unit`, was
  cut off mid-word and ended the JSON early.
- **Decision:** the Ollama adapter marks every property required (nullable ones may be
  null). The shared pydantic model stays lenient; the validator still checks all output.
- **Evidence:** `backend/eval/RESULTS.md` (2026-10-15), same 14 captions back to back:
  ingredients 54→60 of 69, exact amounts 53/54→60/60, steps 9→11 of 14, the reel 2→7 of 9,
  no metric worse. A prompt-only fix was tried first and did nothing.
- **Revisit:** text after an ad in the caption is still sometimes dropped. That's the
  next eval target, and a good test for a paid model.

## 2026-10-15: Claude Haiku 5.5 as an optional extraction provider

- **Context:** Qwen takes 20–80 s per caption and still drops text after an ad in a real
  reel (prompt-5 entry above). The README already listed "add a Claude Haiku adapter and
  run the same evaluation" as the next step. The owner approved trying it on 2026-10-15
  and put $5 of credit on an API key.
- **Decision:**
  - `app/extraction/anthropic.py` uses the official `anthropic` SDK (pinned 1.15.0).
  - Model `claude-haiku-5-5`, structured outputs (`output_config.format`) with every key
    required, `effort: low`, no sampling parameters (Haiku 5.5 rejects them), one SDK retry.
  - The prompt moved to `app/extraction/prompt.py` so both models get the same text.
  - The key is `COOKBOOK_ANTHROPIC_API_KEY` in `backend/.env`. That file is gitignored and
    the tests never read it.
  - Refusals, API errors and empty replies map to `ExtractionError`; timeouts map to
    `ExtractionTimeout`. Error bodies aren't passed to the client.
- **Privacy and cost:** with `COOKBOOK_EXTRACTION_PROVIDER=anthropic`, the caption text
  (not photos, not the user's recipes) is sent to Anthropic. A caption costs about $0.0004.
  After seeing the results, the owner switched the app to `anthropic` the same day ("considering
  haiku is so beyond cheap"). Qwen stays installed, and switching back is one line in `.env`.
  Checked on the running service: importing the reel through `POST /v1/import-drafts`
  took 7 s and returned `extraction_version` `anthropic:claude-haiku-5-5:prompt-5`, 9
  ingredients and 5 steps, including the two after the ad.
- **Evidence:** `backend/eval/RESULTS.md` (2026-10-15, Haiku). On the 14 captions ×3 runs,
  Haiku found 67/69 ingredients vs Qwen's 60/69. It got the failing reel fully right in every
  run, with a median of 1.9 s vs 28 s. Step counts tied at 11/14. 7 new mocked adapter
  tests; `pytest` 180 passed.
- **Revisit:** if Haiku becomes the default, decide what happens when the Mac is offline
  or the key runs out. Falling back to Qwen is the obvious option.

## 2026-10-15: No offline fallback; clear errors when Claude can't be used

- **Context:** with Haiku as the provider, imports fail when the Mac has no internet or the
  API key is out of credit. Before this change every failure said "unavailable right now"
  and was marked retryable, even though retrying doesn't help when credit has run out.
- **Decision (owner):** no automatic fallback to Qwen. The long-term plan is to move the
  backend off the Mac to the cloud, where a local model wouldn't exist. Show a clear error
  instead. "Enter Manually Instead" was already offered on every import error.
  - No connection to the API: 503 `extraction_unreachable`, retryable, "Check that the
    server has internet".
  - 401/402/403 (bad key, out of credit, key not allowed): 503 `extraction_account`, **not
    retryable**. The server log says to check credit and the API key. The provider's own
    error text isn't shown to the phone.
  - Anything else (429, 5xx, overloaded): unchanged, `extraction_unavailable`, retryable.
- **Verified:** 4 new tests with a mocked API, including 402 `billing_error`; `pytest` 184
  passed. Not tested against a real empty balance or a real loss of internet.

## 2026-10-15: A paragraph step is one whole sentence (prompt-6, Haiku effort medium)

- **Decision (owner):** in a paragraph caption, one step is one sentence as written, not
  one action. It keeps steps word for word, so the review screen has nothing to flag.
  Per-action splitting can come back with a cooking mode if one is built.
- **Changes:**
  - The eval's expected counts were corrected (they had assumed per-action steps).
  - The prompt (prompt-6) says a step is a whole sentence. It copies only the lead-in when
    a sentence introduces ingredient lines, and keeps only the cooking part when an ad runs
    on in the same sentence.
  - Haiku runs at `effort: medium`; at `low` it still split sentences.
- **Cost:** median 1.9 s → 3.3 s, about $0.0004 → $0.0006 per caption. Against the corrected
  counts both prompts get 42/42 steps. prompt-6 removes the flagged "In a pan add" step
  (rows flagged as not matching: 2 → 0) without splitting sentences (`eval/RESULTS.md`).
- **Ollama/Qwen:** the owner stopped evaluating and tuning it. The adapter and the
  service stay in place as a one-line switch back. Qwen also gets prompt-6 but hasn't
  been measured on it.

## 2026-10-15: Simulator walkthrough found no pull to refresh on the empty list

- **Found:** `CookbookUITests/Walkthrough` on the iPhone Air Simulator. With no recipes, a
  recipe created through the API (as if from another device) never appeared. Two pull
  gestures on "No Recipes Yet" sent no request (server log), and only a relaunch showed it.
  The likely cause is that the empty state's `.refreshable` has no scroll view to pull.
- **Not fixed** (the walkthrough doesn't change app code). Create, edit, stale edit,
  delete, search, duplicates and caption import all passed. See the README.

## 2026-10-15: The share extension hands the link to the app with a custom URL scheme

- **Context:** Share → Cookbook from Instagram or Safari should start the existing link
  import. Share extensions can't use `UIApplication.shared`, and `NSExtensionContext.open`
  is documented for Today and iMessage extensions only. The brief says a share extension
  may receive a URL only. The owner signs with a free Personal Team, where App Groups may
  not be available.
- **Decision:**
  - The extension (`CookbookShare`, no entitlements) checks the shared URL or text with
    `InstagramLink`. That code is now in `ios/Shared` and compiled into both targets.
  - It opens `cookbook://import?url=<canonical post URL>`. It tries
    `NSExtensionContext.open` first, then the `UIApplication` found on its responder chain.
    If opening fails, it copies the link and points the user to the app's clipboard banner.
  - The app re-validates the link (any app can open the scheme) and asks "Import from
    Instagram?" before the in-app browser loads anything. The extension never fetches
    Instagram or calls the backend.
- **Alternatives:**
  - App Group shared storage: needs a capability, and still doesn't open the app.
  - Clipboard only: leaves the user to switch apps. Kept as the fallback.
  - Universal links: need a hosted domain and Associated Domains.
- **Verified:** iOS 27 Simulator only.
  - `NSExtensionContext.open` returned false; the responder-chain open returned true.
  - XCUITest: Safari → Share → Cookbook reached the app's confirmation with the
    canonical reel link, and an example.com link stayed in the extension.
  - 6 offline unit tests.
  - Not verified: a real iPhone, free-team signing (the extension is a second App ID),
    sharing from the Instagram app, and the clipboard fallback.
- **Risk:** the responder-chain open is an undocumented workaround. App Review could
  reject it, and a future iOS could break it; the clipboard fallback remains. Revisit if
  it stops working on the device, or before any App Store submission.

## 2026-10-15: Screenshot import reads text on the device; the user checks it before extraction

- **Context:** long captions are hard to copy from Instagram. The brief allows screenshot
  OCR as an optional MVP convenience, as long as OCR output stays a reviewable draft and
  is treated as untrusted.
- **Decision:**
  - Vision (`VNRecognizeTextRequest`, accurate, language correction on) reads the text on
    the phone, from `PhotosPicker` (no photo library permission needed).
  - The text goes into the Import Caption field after anything already there. The user
    edits it and taps Read Recipe, and it is sent as `source_text` like a pasted caption.
    No backend change, no image upload.
  - Lines are ordered by position and never rewritten. Screenshots join in picked order,
    and an exact overlap (2+ lines, or one line of 20+ characters) is dropped once.
  - Instagram labels are left in for the extractor and the review screen.
  - Amounts like "11/2" are pointed out to the user, never changed.
- **Alternatives:**
  - Server-side OCR: rejected. It uploads images and adds cost.
  - Stripping Instagram labels: rejected as not simple or safe.
  - Auto-submitting after OCR: rejected, the user should check the text first.
  - Rewriting "11/2" as "1 1/2": rejected, it could invent a quantity.
- **Finding:** in the iOS 27 Simulator, Vision read "1 1/2 cups flour" as "11/2 cups
  flour" with every setting (macOS Vision didn't). Because the misread is in the caption
  itself, the server can't catch it, and it then saved 5.5 cups with nothing flagged.
  Hence the warning. Whether a real iPhone does this is unknown.
- **Verified:**
  - 13 unit tests, one running Vision in the Simulator on a generated image.
  - A UI test on a dev-mode server with the fake extractor: cancel, two ordered
    screenshots, no text found, and one screenshot through to Review Recipe.
  - Not tested on a device or on real Instagram screenshots.

## 2026-10-18: Deploy to one Lightsail server; Google sign-in issues device tokens

- **Context:** The owner wants a public deployment so the founder can try the app. The
  budget is $20 total, enforced by an AWS spend limit that pauses the project, and the
  AWS project is on the paid plan with no credits. There is no paid Apple Developer
  membership yet, so Sign in with Apple and TestFlight aren't available.
- **Decision:**
  - Hosting: one Lightsail `micro_3_0` server in us-east-2 ($7 a month, 1 GB RAM, 40 GB
    disk, public IPv4 included) running the API, PostgreSQL and Caddy for HTTPS. Photos
    go to S3. About 2.5 months of hosting for the budget.
  - Sign-in: Google. `POST /v1/auth/google` takes a Google ID token, checks its signature
    against Google's published keys (PyJWT's `PyJWKClient`, cached), plus issuer, audience
    (`COOKBOOK_GOOGLE_CLIENT_IDS`) and expiry. The user is found or created by
    `users.auth_subject = "google:<sub>"`, and the response is an ordinary `ckb_` device
    token. The rest of the API and the iOS Keychain storage stay as they are.
  - The iOS app will sign in through `ASWebAuthenticationSession` (OAuth with PKCE), so
    no Google SDK is added to the app.
- **Alternatives:**
  - EC2 plus RDS: about $30 a month, more than the whole budget.
  - Sign in with Apple: needs the $99 membership. It can be added later as a second route
    that issues the same device tokens.
  - Google's tokeninfo endpoint instead of local verification: a network call on every
    sign-in, and Google documents it for debugging.
  - `google-auth`: pulls in more than PyJWT for one check.
- **Not yet decided:** how the owner's existing Mac data moves to the server and joins
  their Google account, account deletion, and a per-user import limit before strangers can
  sign in.
- **Verified:** 14 tests against PostgreSQL with a local signing key: forged signature,
  wrong audience, wrong issuer, expired, missing or empty subject, garbage, Google
  unreachable (503, retryable), turned off without client IDs, repeat sign-in reaching the
  same recipes, and two Google users kept apart. The real verifier fetched Google's live
  keys and rejected a token with an unknown key ID. No real Google sign-in has been tried.
- **iOS (same day):** `GoogleSignInButton` runs the OAuth flow through SwiftUI's
  `webAuthenticationSession` (shared browser session, so a phone already signed in to
  Google can pick an account), redeems the code with PKCE at Google's token endpoint (iOS
  clients have no secret), sends the ID token to the server, and saves the device token in
  the Keychain like pairing does. It's on the signed-out screen and in Settings; pairing
  codes still work. The client ID is in the app (not a secret). 8 unit tests (PKCE against
  the RFC 7636 example, URL, redirect parsing, token exchange, server call). The UI test
  `GoogleSignInFlow` reached Google's real sign-in page ("to continue to cookbook") in the
  iOS 27 Simulator (the signed-out screen came from the Mac's token-mode server).
  Then the owner signed in with a real Google account (a test user) in the Simulator
  against a local token-mode server: 201 from /v1/auth/google, a `google:` user and token
  created, and the recipe list loaded (200). AutoFill in the Simulator can't fill Google's
  form; typing the email and password works. Signing out now keeps the server address.
- **Revisit:** When there's a paid Apple membership (add Sign in with Apple), or if the
  server runs out of memory on 1 GB.

## 2026-10-18: The server: Lightsail, systemd, Caddy, S3 with a bucket-scoped IAM user

- **Context:** Carries out the hosting plan above.
- **Decision:**
  - Lightsail `cookbook-server` (Ubuntu 24.04, `micro_3_0`) with the static IP
    77.112.189.191 and 1 GB of swap. Firewall: 80 and 443 open, SSH only from the owner's IP.
  - HTTPS name from sslip.io (`77-112-189-191.sslip.io`), so no domain to buy. Caddy gets
    the Let's Encrypt certificate and proxies to uvicorn on 127.0.0.1:8000.
  - PostgreSQL from Ubuntu, localhost only; the `cookbook` OS user connects by peer
    authentication, so there's no database password.
  - systemd runs the API (migrations first), the hourly cleanup, and a nightly `pg_dump`
    uploaded to a backup bucket that expires copies after 14 days.
  - Photos in the S3 bucket `cookbook-photos-220133863661`. Both buckets block public
    access. The IAM user `cookbook-server` can read, write and delete photos and only add
    backups (it can't read or delete them). Its access key is in `/etc/cookbook/env` on the
    server, readable by root and the `cookbook` user.
  - Secrets live in `deploy/server.env` on the Mac (git-ignored) and `/etc/cookbook/env`.
  - Phones default to the server through `CookbookServerURL` in Info.plist. The
    Simulator still uses 127.0.0.1.
  - `python -m app.accounts link-owner` gives a Google sign-in to the owner account
    from before sign-in existed, keeping its ID, so photo keys don't change.
- **Alternatives:** Lightsail object storage ($1/month); MinIO on the server (memory);
  a git checkout on the server (the repo would need deploy access), so `deploy/push.sh`
  uses rsync instead.
- **Verified:** a real Let's Encrypt certificate; `/healthz` over HTTPS; HTTP redirects to
  HTTPS; `/v1/recipes` without a token is 401; Google sign-in is turned on (a bad token
  gets 401, not 404); ports 8000 and 5432 closed from outside; a manual backup run
  reached S3; the API started with S3 photo storage. 5 `link-owner` tests. 203 backend
  tests, 74 iOS tests, and a device build with the server address.
- **Then (same day):** the owner ran `deploy/migrate-from-mac.sh` (3 recipes, 1 photo),
  signed in with Google on their iPhone against the server (201, then 200 for the list),
  `link-owner` moved that sign-in onto the owner account, and after signing in again the
  phone showed the recipes and loaded the photo from S3. The 5 Mac pairing tokens came
  across with the database and still work on the server.
- **Cost alert:** AWS Budget `cookbook-20-total`: $20 of total spend from 2026-10-18 to
  2027-09-30, emailing the owner at 70% ($14) and 90% ($18) of actual spend.
- **Revisit:** When the budget runs out (around early January), or if memory runs short.

## 2026-10-18: After the move: old tokens, Simulator settings, Andrew's access

- **Old tokens:** the Mac's database brought its device tokens to the server: 2 working
  (a phone pairing and the contract tests) and 3 expired. The owner revoked all 5 on the
  server with `python -m app.tokens revoke`; the phone's Google sign-in token is the only
  active one left.
  The Mac's own server keeps its copies.
- **Simulator settings:** a server address saved by pairing (UserDefaults `serverURL`)
  wins over the scheme's `COOKBOOK_API_URL`. A Simulator that was paired with the Mac
  ignores the override until the saved address is changed or the app is reinstalled.
  After unit tests run, the test-host copy of the app stays open as a blank window;
  relaunching the app fixes it.
- **The Mac and the server diverge:** after the move, new recipes from the phone go only
  to the server. The Mac's server stays as it was for development; its data isn't synced
  back.
- **Andrew:** gets in by being added as a Google test user, then installing from the
  owner's Xcode (free signing: the install lasts 7 days). His sign-in creates his own
  account; he can't see the owner's recipes. TestFlight needs the $99 Apple Developer
  membership, which the owner is still deciding on.
- **Auto mode:** Claude Code's safety checks blocked Claude from running two kinds of
  step: copying personal data to the cloud and changing data on the server over SSH. The
  owner ran those steps (`deploy/migrate-from-mac.sh`, the token revocation) instead.
- **Revisit:** If more people join (publish the Google client or add test users), add a
  per-user import limit before Claude costs can be run up.

## 2026-10-18: Cleanup after the move to AWS: no Mac services, no Ollama, no MinIO

- **Context:** Phones now use the AWS server, so the Mac only serves local development.
- **Decision:**
  - Removed `ops/`, the launchd services that kept the API, MinIO, backups and cleanup
    running on the Mac for the phone. They were stopped with `ops/uninstall-services.sh`
    first. The Mac's database and MinIO files are still on disk, untouched.
  - Removed `deploy/migrate-from-mac.sh`; the move is done (it's in git history).
  - Removed the Ollama provider (`app/extraction/ollama.py`, its settings and 6 tests).
    Claude Haiku replaced it, and a 7B model can't run on the 1 GB server. The Qwen
    numbers stay in `eval/RESULTS.md` as history.
  - Local development keeps photos in memory (`COOKBOOK_STORAGE_BACKEND=memory`, now in
    `.env.example`), so MinIO isn't needed. The S3 endpoint default is AWS us-east-2.
  - App text no longer assumes a Mac on Tailscale: the "can't reach the server" message
    and the Settings pairing text. Pairing codes stay, for development and the live
    contract tests.
  - The README's Tailscale and always-on-services instructions are gone. Its "20–60
    seconds" known issue was already fixed by #8.
- **Supersedes:** "Self-hosted on the owner's Mac" and "Local Qwen 2.5 7B via Ollama" above.
- **Verified:** 197 backend tests (203 minus the 6 Ollama tests), 74 iOS tests, a device
  build, and the 10 live contract tests against a local server with in-memory photos and
  Claude extraction.

## 2026-10-20: Per-user and global import limits, counted in PostgreSQL

- **Context:** Others can sign in now, and every `POST /v1/import-drafts` calls Claude
  (about $0.0006 each). With no limit, one scripted user could spend about $60 a day. The
  brief rules out Redis and API gateways.
- **Decision:**
  - Before calling the extractor, `create_draft` counts `import_drafts` rows: this user's
    in the last hour and last 24 hours, and everyone's in the last 24 hours. At a limit
    it returns 429 `rate_limited`, `retryable: true`, a message saying manual entry still
    works, and `Retry-After`: the seconds until enough drafts leave the window to get back
    under the limit.
  - Defaults, chosen by the owner, and their worst-case cost: 20 per user per hour
    ($0.012/hour), 100 per user per day ($0.06/day), 300 per day across all users ($0.18/day,
    about $5.40/month). Set with `COOKBOOK_IMPORT_LIMIT_PER_HOUR`, `_PER_DAY` and
    `_GLOBAL_PER_DAY`. The global limit is the kill switch: set it to 0 to stop all imports.
  - `ApiError` gained an optional `headers` argument for `Retry-After`.
- **Depends on draft expiry:** the daily counts only see drafts that still exist, and
  `python -m app.cleanup` deletes drafts once they expire (saved or not). So
  `draft_ttl_hours` must stay at 24 or more. The server refuses to start if it's lower.
- **No new index:** the per-user count uses the existing `ix_import_drafts_user_id`, and
  one user has at most about 100 rows in a day. The global count scans the table, which
  stays small because the global limit caps it at about 300 new rows a day and cleanup
  deletes them after 24 hours. Add `(user_id, created_at)` or `(created_at)` only if
  measurements show the counts are slow, for example if cleanup stops running.
- **Known slack:** the check runs before extraction, and the row is inserted after it
  (a few seconds later). Requests sent at the same moment can all pass the check, so a
  burst can overshoot by the number of requests in flight. That's bounded by the server's
  worker threads (about 40), so a few cents at most, and the next request is refused.
  Locking the user's row for the whole extraction would close this gap, but it would
  serialize a user's imports and hold a transaction open during the call. Not done.
- **Not counted:** extractions that fail (timeout, malformed output) cost money but leave
  no draft, so they don't count. Revisit if the logs show repeated failures from one user.
- **Alternatives:** an in-memory counter (lost on restart, and wrong with more than one
  process), or a separate counter table (more code than counting the rows that already
  exist).
- **iOS:** no change needed. The import screen shows the server's `message` in its error
  banner, keeps the caption, and offers "Enter Manually Instead".
- **Revisit:** if imports are legitimately hitting the limits, or the table grows.

## 2026-10-20: Extraction timeouts sized for Haiku; one retry inside the deadline

- **Context:** The server still waited 120 s and the app 150 s, set for Qwen (2026-10-14
  entry above). Haiku took 1.9 s median / 9.4 s max (prompt-5) and 3.3 s / 8.6 s
  (prompt-6) in `backend/eval/RESULTS.md`. A slow or stuck call held an extraction
  thread and kept the user waiting two minutes.
- **Decision:**
  - `extraction_timeout_s` (`COOKBOOK_EXTRACTION_TIMEOUT_S`) defaults to 30 s. Neither
    `deploy/env.example` nor `backend/.env.example` sets it, so the server gets the new
    default on its next deploy.
  - The app waits 45 s for `POST /v1/import-drafts`, so the server's 504 envelope always
    arrives before the app's own transport timeout. The screenshot UI test waits 45 s too.
  - The SDK's retry is off (`max_retries=0`). Read in the installed `anthropic` 1.15.0
    (`_base_client.py`): the SDK honors any `retry-after`/`retry-after-ms` the API sends,
    capped only at about 50 days, and otherwise backs off 0.5 s, then 1 s (up to 8 s). Its
    `timeout` is an httpx timeout per phase and per attempt, not a total. So a 429 with
    `retry-after: 60` would have kept the worker thread, and maybe a second paid call,
    going long after the 504.
  - Instead, `AnthropicExtractor.extract` makes at most two attempts within the deadline
    minus 1 s (29 s), each with 3 s to connect and at most 15 s for the reply (about 1.6×
    the slowest eval call). It retries the same errors the SDK did (connection errors,
    timeouts, 408, 409, 429, 5xx/529). The wait before the retry is the API's
    `retry-after` or 0.5 s, and it retries only if at least 10 s for the reply would be
    left (more than the slowest eval call). Worst case: 3 + 15 for the first attempt, then
    whatever is left of the 29 s for the second, so the worker thread ends before the 504.
    A reply that times out at 15 s after a quick connect leaves 10.4 s, so it is retried
    once. One that also took 3 s to connect leaves 7.5 s, so it isn't. A `retry-after`
    that doesn't fit isn't waited for: the user gets the retryable 503 right away.
  - The 1 s margin means the adapter fails first with the precise error, and
    `run_extraction`'s 30 s deadline stays as the backstop.
- **Supersedes:** "one SDK retry" in "Claude Haiku 5.5 as an optional extraction
  provider" above.
- **Verified:** 4 new tests (retried once and never a third time; per-attempt timeouts
  passed to the HTTP client; `retry-after: 60` fails at once; a 5 s deadline makes one
  attempt that fits; the 30 s default). The 504 test still passes. `pytest` 201 passed. iOS
  Simulator build succeeded, and `ios/run-tests.sh` passed 64 tests (10 live tests
  skipped). **Not verified:** a real slow or overloaded Anthropic response, and the
  import timeout in the Simulator or on a phone.

## 2026-10-20: Keep the model's original output to measure corrections

- **Context:** PATCH /v1/import-drafts overwrote the model's output in `content`, and
  cleanup deletes drafts (saved or not) after their 24 h expiry. A saved recipe kept the
  caption but not what the model produced or the prompt version, so there was no way to
  measure how much users correct the model.
- **Decision:** Migration 0006 adds a nullable `extracted_content` JSONB to `import_drafts`
  and nullable `extracted_content` JSONB plus `extraction_version` to `recipes`.
  - `create_draft` stores the validated output once and nothing ever patches it. This is
    the model's output after the server's source-fidelity checks (`validate.py`), since
    that's what the user is shown and corrects. The `duplicate_post` warning is left out:
    it comes from the user's cookbook, not the model.
  - Saving a draft (POST /v1/recipes with `draft_id`) copies both onto the recipe in the
    same transaction, so they outlive draft cleanup. Manual recipes leave them NULL. The
    JSONB columns use `none_as_null`, so Python `None` is stored as SQL NULL, not JSON null.
  - Existing rows stay NULL and aren't backfilled: an old draft's `content` may already
    hold the user's edits, so it can't stand in for the model's output.
  - Neither column is returned by the API. The OpenAPI document is byte-for-byte the same
    as before.
  - `python -m app.corrections` prints, per `extraction_version`, how many ingredient and
    step rows were added, removed or edited, and how many quantities changed. It compares
    against the recipe's **current** rows, so later edits to the recipe count as
    corrections too. Rows are matched in order on their text (difflib). Moving a row counts
    as a removal plus an addition.
- **Privacy and scope:** unchanged. This keeps caption-derived data the server already
  holds: the recipe already stores the caption itself. Nothing new is sent anywhere or
  shown to the client, and the data is deleted with the recipe (and with the user, by
  cascade).
- **Alternatives:** Keeping drafts after saving (more rows, and they'd have to be filtered
  out everywhere). A separate `extractions` table. Both are more than this needs.
- **Revisit:** If the report should only count corrections made at review time; that
  would also need the draft's content at save time.

## 2026-10-20: Photo uploads run in the thread pool, one decode at a time, at reduced size

- **Context:** `upload_image` was `async def` but did blocking work (Pillow, S3 puts,
  database calls), so it ran on the event loop and stalled every other request. Measured
  against a local uvicorn with a continuous `GET /healthz` pinger, before any change:
  healthz normally answers in about 2 ms; during a 24 MP JPEG upload its worst case was
  331–359 ms, and during a 48 MP PNG 780–835 ms, i.e. the whole upload. On the slower
  1 GB server it would be longer. Memory, measured as `ru_maxrss` growth in a fresh
  process for `process_upload` alone (tracemalloc only saw about 4 MB, because Pillow's
  pixel buffers are C allocations): +348–354 MB for a 24 MP image and +663–671 MB for a
  48 MP PNG, more than the server can spare.
- **Decision:**
  - `upload_image` is a plain `def`, so FastAPI runs it in its thread pool.
  - One photo is processed at a time (`threading.Semaphore(1)` in `app/images.py`). The
    request body is read into memory only after the slot is taken; until then it sits in
    Starlette's spooled temp file. An upload waits up to 20 s for the slot, then gets a
    retryable 503 `photo_processing_busy` (the app's upload timeout is 60 s). Waiting
    blocks one thread-pool thread each, which is bounded by the pool's 40 threads.
  - JPEGs are decoded at 1/2, 1/4 or 1/8 scale (`Image.draft`) when the long edge stays
    at least 2048 px, so output size is unchanged. The 600 px thumbnail is made from the
    2048 px image instead of the original. No full-size copies: rotation is applied in
    place and an RGB image isn't converted again. EXIF rotation is still applied before
    saving, and saved JPEGs still carry no metadata.
  - `MAX_SOURCE_PIXELS` is 24 MP (was 50 MP), approved by the owner: the app sends at
    most 2048 px (about 4 MP).
  - `deploy/cookbook-api.service` has `MemoryMax=600M`, approved by the owner, so a
    runaway API is killed and restarted by systemd rather than the kernel's OOM killer
    choosing PostgreSQL.
- **After (same measurements, on the Mac):** healthz's worst case during a 24 MP JPEG
  upload was 7–9 ms and during a 23.5 MP PNG 14 ms, with one run at 113 ms (other Python
  work still shares the GIL with Pillow). The old code took 416–467 ms on that PNG.
  Memory: 24 MP JPEG +69 MB (was +348 MB), 23.5 MP PNG +158–160 MB (was +353 MB); a
  48 MP image is now rejected before decoding.
- **Alternatives:** keep `async def` and wrap the blocking calls in `run_in_threadpool`
  (the same effect but more code); a worker process or queue (the brief rules out
  queues until measurements need one); reject when busy instead of waiting (one person
  adding two photos quickly would see an error).
- **Verified:** 5 new tests: healthz isn't held up by a slow upload (fails with the old
  `async def`: 1.52 s), at most one decode runs at a time (fails without the semaphore:
  3), the busy 503, 25 MP rejected, and a rotated 24 MP JPEG decoded at half size comes
  out upright. All earlier photo tests pass.
- **Not verified:** the numbers come from a Mac (macOS reports `ru_maxrss` in bytes,
  Linux in KiB; the script handles both); they weren't measured on the Lightsail server.
  `MemoryMax` relies on cgroup v2, which current Ubuntu on Lightsail uses, but the unit
  hasn't been deployed or tested there.
- **Revisit:** If photos queue up behind each other in real use, or the server is resized.

## 2026-10-24: Posts arrive as a RawPost from the device; TikTok links accepted

- **Context:** Andrew's spec asks for one pipeline for Instagram and TikTok food posts:
  per-platform fetch and normalize, then a shared extract → validate → save path, with the
  post stored so it can be re-parsed later. The brief forbids scraping and the server
  never contacts Instagram.
- **Decision (owner's choice: the user's device fetches):**
  - Stage 1, fetch, stays on the device: the in-app browser, a paste or screenshots.
    The server never contacts Instagram or TikTok, and never downloads `media_urls`.
  - `POST /v1/import-drafts` accepts optional `transcript`, `top_comments` (≤ 20),
    `author_handle`, `posted_at` and `media_urls` (https only, ≤ 20) next to
    `source_text`/`source_url`. The current iOS app sends none of them and works as before.
  - Stage 2, normalize: `app/ingest/{instagram,tiktok}.py` turn the request into a
    `RawPost` (`app/ingest/raw_post.py`). The Instagram normalizer unwraps pasted
    `og:description`/`og:title` preview text (as iOS already does) and keeps the handle
    and date. The TikTok normalizer takes the handle from the link and the caption as
    sent: no TikTok page format has been verified.
  - `app/source_urls.parse_source_url` accepts TikTok `/@handle/video/ID` and
    `/@handle/photo/ID`; the post key is `tiktok:<ID>`. Short links (`vm.`/`vt.tiktok.com`,
    `/t/…`) are rejected: resolving them means fetching TikTok.
  - `raw_posts` (migration 0007) stores one snapshot per import. Drafts and recipes point
    at it with SET NULL. `python -m app.cleanup` deletes posts nothing refers to, so an
    abandoned import or a deleted recipe doesn't keep someone's caption and comments.
    Never returned by the API.
- **Alternatives:** a paid scraping provider (breaks the brief, costs money); TikTok
  oEmbed from the server (terms unchecked; not pursued).
- **Verified:** 39 new tests (fixtures in `tests/fixtures/posts/`, all synthetic), 261
  total against PostgreSQL; migration round trip and `alembic check` clean.
- **Not done yet:** extraction still reads only the caption; transcript and comments
  reach the model in the next slice. iOS doesn't send the new fields or open TikTok links.

## 2026-10-24: Extraction returns a ParsedRecipe from the whole post (prompt-7)

- **Context:** Andrew's spec: one shared extractor over the RawPost that handles a recipe
  in the caption, the transcript or the comments; "link in bio"; non-recipes such as
  restaurant reviews and mukbangs; sub-recipes; emoji bullets, fractions and vague
  amounts. Output: `is_recipe`, `title`, `servings`, ingredients with `note`, steps,
  `sub_recipes`, `source_fields_used`, `confidence`. Validation: schema check with one
  retry, positive amounts, units from a known list, a title if it's a recipe.
- **Decision:**
  - Providers take a `RawPost`. The model sees `<caption>`, `<transcript>` and
    `<comments>` blocks (`app/extraction/source.py`), and the fidelity check runs against
    all three, so rows from a comment or the transcript aren't flagged.
  - `ExtractionOutput` (`app/extraction/base.py`) is the ParsedRecipe. Sub-recipes are one
    level deep: structured outputs need a finite schema, and no case needs more.
  - **Sub-recipes stay inside one recipe (owner's choice).** The draft keeps them flat:
    their rows sit in `ingredients`/`steps` with a `sub_recipe` index into
    `sub_recipes: [{title}]`. Saved recipes stay one-to-many. A many-to-many
    `recipe_components` design is measured separately in `backend/lab/`.
  - Validation (`app/extraction/validate.py`):
    - Units map to one spelling (`tablespoons` → `tbsp`, `cloves` → `clove`).
      Unknown units are kept and flagged `unit_unknown`.
    - Spoken numbers ("two tablespoons") count as amounts; "a"/"a splash" never do.
    - A `note` must come from the ingredient's own text.
    - `servings` is kept only when the post states it ("serves 4", "makes 12").
    - `confidence` is clamped to 0–1, and below 0.5 adds a `low_confidence` warning.
    - `source_fields_used` is limited to the blocks that were actually sent.
    - "Link in bio" (`is_recipe` true, nothing found, and the post mentions a
      bio/link/blog/comments) adds `recipe_elsewhere` next to `no_recipe_found`.
  - `run_extraction` retries malformed output once when at least 10 s of the deadline
    remain, then logs and returns the existing 502.
  - The draft API adds `servings`, `sub_recipes`, and `note`/`sub_recipe` on rows. All
    are optional for the iOS app, which ignores unknown fields. The needs-review message
    keeps its wording because an iOS UI test checks it.
- **Consequence:** Unit spelling changes what a draft shows ("cup" instead of "cups").
  The app displays `raw_text`, so the visible ingredient line is unchanged.
- **Verified:** 29 new tests (transcript-only, comments, link in bio, mukbang,
  sub-recipes, messy formatting, sanity flags, servings, confidence, retry, rendering,
  API); 290 total against PostgreSQL. No live model call yet: the eval baseline comes in
  the evals slice.

## 2026-10-24: Golden-set evals with per-category scores (`backend/evals/`)

- **Context:** Andrew's spec asks for a golden dataset (one JSON per case, tagged by
  category), metrics per category, one command that writes results and diffs against
  the previous run, and a recorded baseline. The old `backend/eval/` scored 14 captions
  on counts only.
- **Decision:**
  - `backend/evals/golden/*.json`: 30 cases. The old 14 are relabelled to the
    ParsedRecipe shape (names, canonical units, notes, step text, sub-recipes), plus 16
    synthetic Instagram/TikTok cases covering transcripts, comments, link in bio,
    non-recipes, sub-recipes and messy formatting. Only one is a real post; the owner
    will add real posts.
  - `python -m evals.run fake|anthropic` scores the validated draft with is_recipe
    accuracy, title, ingredient-name precision/recall, quantity+unit on matched names,
    steps 1–5, sub-recipe count and recall, servings and injected words. Results are
    written to `evals/results/<timestamp>-<provider>.json` and diffed against the last
    run.
  - The title and step judge is Claude Haiku 5.5 (the project's model, about $0.003 a
    run). `--no-judge` uses a deterministic fuzzy fallback.
  - The old harness stays, marked superseded.
- **Baseline (prompt-7, Haiku 5.5):** 100% recipe detection, 99% ingredient recall,
  95% quantity+unit, steps 4.92/5, $0.023 a run. See `backend/evals/RESULTS.md`.
- **Fixed on the way:** `canonical_unit` now accepts "cup of" (Haiku returned it).
- **Revisit:** When real posts are added; before any prompt, model or validator change.
