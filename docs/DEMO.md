# Demo script and deep-dive notes

For the mock project deep dive with Andrew. Everything here was built and measured in this
repo: numbers come from `backend/eval/RESULTS.md`, test runs, and `docs/DECISIONS.md`.

## 30-second pitch

A personal cookbook for recipes I find on Instagram. I copy a reel's link and the app
reads the caption. Claude Haiku turns it into a draft in a few seconds, and the server
checks every ingredient and amount against the caption, so nothing is invented. I review
the draft, save it once, and can search it by ingredient later. It's a native SwiftUI app
with a FastAPI and PostgreSQL backend that I self-host on my Mac; the only cost is about
$0.0006 per import. My iPhone reaches it privately over Tailscale.

## 5-minute live demo (on the iPhone)

1. **List and search.** Open the app and show thumbnails. Search an ingredient ("garlic"):
   matches come from titles *or* ingredients, each recipe appears once, and search is
   debounced, cancelling stale requests.
2. **Instagram import (the core feature).**
   - In Instagram: Share → Copy link on a recipe reel. Switch to Cookbook, and the banner
     says "You copied a link. Import it?".
   - The reel opens in a **logged-out** in-app browser. Tap Import Recipe, and the caption
     is read from the page.
   - Claude Haiku 5.5 reads it in about 3 s. *Mention that a local Qwen 7B took 20–80 s
     and missed text after an ad, which is why the app switched.*
3. **Review.** The original caption is shown above the draft. Orange flags mark rows that
   didn't match the caption. "1/2 cup" keeps its wording, "salt to taste" has no amount,
   and there's no invented title. Fix a row and Save.
4. **Duplicate safety.** Import the same reel again. You get "Already in your cookbook",
   with Open Existing or Save Anyway.
5. **Photo.** Add a photo. Mention that GPS is stripped server-side and the photo is
   served by an expiring signed URL.
6. **Edit and conflict, if there's time.** Edit a recipe while it's changed from another
   device (`curl` PATCH). The app keeps your edits and offers Save My Version or Reload.

## Architecture in five lines

- **iOS:** SwiftUI, iOS 17+, `@Observable`, URLSession. No local database: the server is
  the source of truth, and failures keep unsaved text on screen.
- **API:** FastAPI with `/v1` routes, Pydantic contracts with `extra="forbid"`, and one
  error envelope (`code`, `message`, `field_errors`, `retryable`, `request_id`).
- **Data:** PostgreSQL with hand-written Alembic migrations, and `alembic check` in the
  tests. Recipes have ordered ingredient and step rows, plus import drafts, idempotency
  keys, photo metadata and device tokens.
- **AI:** a provider adapter: the rule-based fake for tests, Claude Haiku 5.5 in use
  (prompt-6, structured outputs), Qwen 2.5 7B via Ollama kept as a one-line switch back.
  Every provider's output goes through the same **source-fidelity validator**.
- **Hosting:** launchd services on my Mac, with MinIO for photos, Tailscale `serve` for
  HTTPS reachable only from my devices, nightly `pg_dump`, and hourly cleanup.

## Tradeoffs ("I chose X because Y, gave up Z, I'd switch if W")

| Decision | Why | Gave up | Switch when |
|---|---|---|---|
| Self-host on my Mac + Tailscale | $0 hosting, private, one user | Availability when the laptop sleeps | Needs to work with the laptop off, or more users |
| Claude Haiku 5.5 over the API (switched from local Qwen) | 67/69 vs 60/69 ingredients, about 3 s vs 28 s median, about $0.0006 a caption | Captions leave the Mac; no import without internet or credit (a clear error, then manual entry) | Privacy matters more than speed: Qwen is one line in `.env` |
| Validator after the model | Works for *any* model, and the brief forbids invented amounts | Can't judge text quoted verbatim from the caption (a known, tested limit) | Never; it's the safety net |
| Device tokens, not managed auth | One owner, no third-party account | JWT/OIDC features, multiple users | Before a second user or public deploy |
| In-app logged-out browser for Instagram | The only way to match ReciMe; oEmbed's terms forbid extraction | It's a ToS gray area, and Instagram can change the page | Meta offers a permitted caption API |
| Server-signed photo URLs, not presigned S3 | One origin over Tailscale; deletes take effect immediately | Offloading bytes to the bucket/CDN | Move to R2 with a CDN |
| Optimistic concurrency (`version` + row lock) | No lost updates, simple | Field-level merge | Collaborative editing |
| ILIKE search, no index | Personal scale; the brief says improve Postgres first | Ranking, fuzzy matching | Thousands of recipes: `pg_trgm` GIN indexes |

## Things I'd bring up unprompted

- **The validator found real model bugs.** Qwen wrote units as `"cup(s)"`, left names
  empty, merged comma lists, called an injected caption "not a recipe", and once looped
  `"cups of sugar…"` until it timed out. Each one is fixed and tested. The evaluation
  went from 44/50 to 52/60 ingredients with 0 injected words
  (`backend/eval/RESULTS.md`).
- **The access spike.** I checked Meta's oEmbed: it needs App Review, and its terms
  prohibit "consuming, extracting, or persisting" content. So the server never touches
  Instagram. The phone reads the page the user is looking at.
- **Idempotency.** A retried save with the same `Idempotency-Key` returns the first
  result. The same key with a different body gets 409. Removing the owner-row lock makes
  the concurrency tests fail, which I checked by deliberately breaking it.
- **Tests caught my own mistakes:** tests reading `.env` uploaded to real MinIO, a
  validator rejecting `500g`, and a test client cache hiding a 404. Each was found, fixed,
  and written down.

## Numbers

- Backend: 184 pytest tests against real PostgreSQL (migrations, constraints, auth,
  ownership, concurrency, extraction fixtures, photos).
- iOS: 66 XCTest tests (`ios/run-tests.sh` or ⌘U): 56 offline unit tests (form rules,
  parsing, `APIClient` against a stubbed `URLSession`) and 10 live contract tests that run
  the real Swift client against the live server. Plus two UI tests: a screenshot tour and
  a walkthrough of create, edit, stale edit, delete, search, duplicates and import.
- Haiku evaluation (prompt-6) on 14 captions × 3 runs: 42/42 recipe detection, 202/207
  ingredients, 0 rows not matching the caption, 0 injected words, median 3.3 s. Qwen on
  the same captions (prompt-5): 60/69 ingredients, median 28 s.

## Honest limits and what's next

- Imports need the internet and API credit (Haiku). With neither, the app says so and
  offers manual entry; there's no automatic fallback to the local model.
- No offline cache. The app needs the Mac awake.
- UI tests are a screenshot tour and one walkthrough (`ios/CookbookUITests`), run by hand
  on the Simulator, not in CI.
- Captions only: no reel audio or video. Screenshot OCR (on-device Vision) is the next
  import source.
- Accessibility (checked 2026-10-14):
  - **Dynamic Type at the largest size, with real data:** list rows, the editor's ingredient
    fields and the step rows stack vertically instead of squeezing ("in-gre-di-ents" before
    the fix). Verified with screenshots of the list, a recipe and the editor.
  - **Apple's automated audit** (`performAccessibilityAudit`) on the list, recipe, editor,
    Import and Settings screens, then fixed:
    - "Missing ingredients" orange-on-white contrast
    - the caption placeholder's contrast
    - Quantity/Unit fields clipping their text
    - the ingredients Edit button's 44 pt hit target
    - step numbers being separate VoiceOver stops
  - **Remaining audit findings are system styling:** iOS 27 toolbar buttons, secondary text
    and section headers.
  - **VoiceOver labels**, read from the accessibility tree: list rows read as one element
    ("Tomato pasta, 3 ingredients, 1 step"), steps as "Step 1: Cook pasta.", and
    thumbnails are hidden.
  - **Hands-on VoiceOver on the iPhone**: worked well.
  - Not yet: the iOS 17 runtime.
- Grocery lists and meal planning are deliberately out of scope.

## Questions to practice

1. Walk me through what happens between pasting a link and the recipe being saved.
2. How do you know the model didn't invent "2 cups of flour"?
3. Two phones save the same reel at the same moment. What happens?
4. Why is the API reachable over HTTPS on Tailscale but bound to 127.0.0.1?
5. How would you move this to the cloud, and what changes in the code?
6. SSE vs. WebSockets: would you stream extraction progress, and how?
   (SSE: one-way server→client over plain HTTP, reconnects automatically. WebSockets are
   only worth it for two-way, real-time traffic.)
7. What's the worst bug you found, and how did you find it?
