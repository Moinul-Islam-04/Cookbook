# Cookbook

A personal cookbook for recipes found on Instagram. Save a post's recipe by sharing it,
pasting its caption or picking screenshots. An AI turns the text into a draft, and you
check the draft before saving it. Saved recipes can be searched by title or ingredient.

- **iOS app:** SwiftUI, iOS 17+, no third-party packages (`ios/`).
- **Backend:** FastAPI and PostgreSQL, with photos in MinIO (`backend/`). It runs on a Mac
  and the iPhone reaches it over Tailscale.
- **Extraction:** Claude Haiku 5.5. The server checks every draft against the caption:
  invented amounts are removed and text that isn't in the caption is flagged for review.
  The server never contacts Instagram.

More detail: [product brief](docs/BRIEF.md) · [engineering decisions](docs/DECISIONS.md) ·
[features and verification log](docs/VERIFICATION.md) ·
[extraction evaluation](backend/eval/RESULTS.md).

## How to run it

### Backend (macOS)

```bash
brew install postgresql@16 && brew services start postgresql@16
createdb cookbook && createdb cookbook_test

cd backend
python3 -m venv .venv && source .venv/bin/activate   # Python 3.11+
pip install -r requirements-dev.txt
cp .env.example .env

alembic upgrade head
pytest -q                       # 184 passed (the test DB is dropped and recreated)
uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

- The API docs are at http://127.0.0.1:8000/docs.
- `.env.example` starts in `dev` mode (no auth, for local use) with the free rule-based
  `fake` extractor.
- To import the way the app does, set `COOKBOOK_EXTRACTION_PROVIDER=anthropic` and
  `COOKBOOK_ANTHROPIC_API_KEY` in `.env`. Captions are sent to Anthropic, at about
  $0.0006 each.
- If your PostgreSQL role isn't your macOS username, set `COOKBOOK_DATABASE_URL` and
  `COOKBOOK_TEST_DATABASE_URL`.

**Always-on services:** `ops/install-services.sh` installs launchd agents that start when
you log in:
- the API on 127.0.0.1:8000 (runs migrations first)
- MinIO on 127.0.0.1:9000
- a nightly `pg_dump` backup, kept 14 days
- an hourly cleanup of expired drafts

Logs are in `~/Library/Logs/Cookbook/`. After pulling backend changes, restart the API
with `launchctl kickstart -k gui/$(id -u)/com.cookbook.api`.

### iOS app

- **Simulator:** open `ios/Cookbook.xcodeproj`, pick a simulator and press ⌘R. It reaches
  a `dev`-mode server on `127.0.0.1` directly. Set `COOKBOOK_API_URL` in the scheme to use
  another server.
- **iPhone:**
  1. Install Tailscale on the Mac and the phone.
  2. Publish the API to your tailnet: `tailscale serve --bg --https=443 http://127.0.0.1:8000`.
  3. Create a pairing code:
     `cd backend && .venv/bin/python -m app.tokens create --name "iPhone" --server https://<mac>.<tailnet>.ts.net`.
  4. Install the app from Xcode with your signing team. A free team's install lasts 7 days.
  5. Paste the pairing code in the app's Settings (gear icon).
- **Tests:**
  - Unit tests: `ios/run-tests.sh` (56 offline tests, plus 10 live contract tests when
    you set `TOKEN=ckb_...`).
  - UI tests (`CookbookUITests`) run with the `Screenshots` scheme. Each file's header
    says what it needs.

## Current status

Milestones 1–5 in the brief are done, and the app runs on the owner's iPhone. Milestone 0's
Instagram access spike was never run.

| Area | State |
| --- | --- |
| Manual recipes | Create, edit, delete, photos. Missing amounts stay empty. An edit made on another device is detected (409) without losing yours. |
| Search and duplicates | Search by title or ingredient. Saving a post twice warns and links to the existing recipe. |
| Import | Paste a caption, or open an Instagram link in the in-app browser. Claude Haiku drafts it (about 3 s), you review flagged rows, then save. When Claude can't be reached or credit runs out, you see a clear error and can enter the recipe manually. |
| Share extension | Share → **Cookbook** from Safari or Instagram. **Simulator only:** not yet tried on the iPhone with free signing. It opens the app through an undocumented workaround (see DECISIONS). |
| Import from screenshots | Text is read on the phone and you check it before importing. **Simulator only.** In the Simulator it read "1 1/2" as "11/2", so amounts like that are pointed out for you to check. |
| Accounts and access | One user, a device token per phone, and the API reachable only on your tailnet. |

**Verified:**
- Backend: 184 tests against PostgreSQL.
- iOS: 66 XCTest tests, plus UI tests.
- Every main flow walked through in the iOS 27 Simulator.
- Imports checked by hand on the iPhone.

**Not verified:** an iOS 17/18 runtime, and the two newest features on a real device.

**Known issues:**
- Pull to refresh does nothing on the empty recipe list.
- The import screen still says "usually 20–60 seconds" (the old local model's speed).

**Out of scope for now** (per the brief): offline use, sharing with friends, nutrition
estimates and video/audio import.

## Next smallest task

1. Try the share extension and screenshot import on the iPhone: does the extension install
   with free signing and open the app? Does sharing from the Instagram app itself work?
   Does on-device text recognition misread "1 1/2" the way the Simulator did?
2. Then fix the two known issues above.
3. Or work on the remaining extraction misses in `backend/eval/RESULTS.md`, adding real
   captions that go wrong to `backend/eval/captions.json`.
