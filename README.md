# Cookbook

A personal cookbook for recipes found on Instagram. Save a post's recipe by sharing it,
pasting its caption or picking screenshots. An AI turns the text into a draft, and you
check the draft before saving it. Saved recipes can be searched by title or ingredient.

- **iOS app:** SwiftUI, iOS 17+, no third-party packages (`ios/`).
- **Backend:** FastAPI and PostgreSQL (`backend/`), on an AWS Lightsail server with
  photos in S3. Sign-in is with Google.
- **Extraction:** Claude Haiku 5.5. The server checks every draft against the caption:
  invented amounts are removed and text that isn't in the caption is flagged for review.
  The server never contacts Instagram.

More detail: [product brief](docs/BRIEF.md) · [engineering decisions](docs/DECISIONS.md) ·
[features and verification log](docs/VERIFICATION.md) ·
[extraction evaluation](backend/eval/RESULTS.md).

## How to run it

### Backend (local development, macOS)

```bash
brew install postgresql@16 && brew services start postgresql@16
createdb cookbook && createdb cookbook_test

cd backend
python3 -m venv .venv && source .venv/bin/activate   # Python 3.11+
pip install -r requirements-dev.txt
cp .env.example .env

alembic upgrade head
pytest -q                       # 290 passed (the test DB is dropped and recreated)
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
- Photos are kept in memory locally, so they're lost when the server restarts. The
  deployed server keeps them in S3.
- Run uvicorn only while you're developing; nothing runs in the background.

### iOS app

- **Simulator:** open `ios/Cookbook.xcodeproj`, pick a simulator and press ⌘R. It reaches
  a `dev`-mode server on `127.0.0.1` directly. Set `COOKBOOK_API_URL` in the scheme to use
  another server.
- **iPhone:** install from Xcode with your signing team (a free team's install lasts 7
  days), then tap **Sign in with Google**. Phone builds use the deployed server. Only
  Google accounts listed as test users in the Google Cloud project can sign in.
- **Tests:**
  - Unit tests: `ios/run-tests.sh` (64 offline tests, plus 10 live contract tests when
    you set `TOKEN=ckb_...`).
  - UI tests (`CookbookUITests`) run with the `Screenshots` scheme. Each file's header
    says what it needs.

### Server (AWS Lightsail)

The API runs at https://77-112-189-191.sslip.io on one Lightsail server (us-east-2,
$7/month) with PostgreSQL, Caddy (HTTPS) and S3 for photos and nightly backups. Phone
builds use it by default; the Simulator uses a local backend.

- Deploy the current code: `deploy/push.sh` (copies `backend/`, installs requirements,
  restarts the API, checks `/healthz`).
- Needs `deploy/server.conf` and `deploy/server.env` (both git-ignored; template in
  `deploy/env.example`) and the SSH key `~/.ssh/cookbook_lightsail`. SSH is open only to
  one IP address: update the Lightsail firewall if yours changes.
- Logs: `ssh -i ~/.ssh/cookbook_lightsail ubuntu@77.112.189.191 journalctl -u cookbook-api`.
- Accounts: `sudo -u cookbook bash -c 'set -a; . /etc/cookbook/env; cd /opt/cookbook/backend && .venv/bin/python -m app.accounts list'`.
- Backups: nightly `pg_dump` to `s3://cookbook-backups-220133863661/db/`, kept 14 days.

## Current status

Milestones 1–5 in the brief are done, and the app runs on the owner's iPhone against the
AWS server. Milestone 0's
Instagram access spike was never run.

| Area | State |
| --- | --- |
| Manual recipes | Create, edit, delete, photos. Missing amounts stay empty. An edit made on another device is detected (409) without losing yours. |
| Search and duplicates | Search by title or ingredient. Saving a post twice warns and links to the existing recipe. |
| Import | Paste a caption, or open an Instagram link in the in-app browser. Claude Haiku drafts it (about 3 s; the server gives up after 30 s), you review flagged rows, then save. When Claude can't be reached or credit runs out, you see a clear error and can enter the recipe manually. Imports are limited to 20 an hour and 100 a day per user, and 300 a day across everyone; past a limit the app says so, and manual entry still works. A saved import keeps what Claude produced (never shown in the app), and `python -m app.corrections` reports how much users corrected it. |
| Share extension | Share → **Cookbook** from Safari or Instagram. **Simulator only:** not yet tried on the iPhone with free signing. It opens the app through an undocumented workaround (see DECISIONS). |
| Import from screenshots | Text is read on the phone and you check it before importing. **Simulator only.** In the Simulator it read "1 1/2" as "11/2", so amounts like that are pointed out for you to check. |
| Post pipeline (backend) | Imports are normalized into a stored `RawPost` (Instagram or TikTok link, caption, optional transcript and comments) before extraction. Claude reads the caption, transcript and comments into a ParsedRecipe (servings, notes, sub-recipes, confidence; prompt-7); see DECISIONS 2026-10-24. TikTok links are accepted by the API but the app doesn't open them yet. |
| Accounts and access | Sign in with Google; each Google account has its own recipes. The owner's recipes moved from the Mac and are linked to their Google account. Only Google test users can sign in. Pairing codes (`python -m app.tokens create`) still work, for development and the live contract tests. |

**Verified:**
- Backend: 290 tests against PostgreSQL.
- iOS: 74 XCTest tests, plus UI tests.
- Every main flow walked through in the iOS 27 Simulator.
- Imports checked by hand on the iPhone.

**Not verified:** an iOS 17/18 runtime, and the two newest features on a real device.

**Known issues:**
- Pull to refresh does nothing on the empty recipe list.

**Out of scope for now** (per the brief): offline use, sharing with friends, nutrition
estimates and video/audio import.

## Next smallest task

1. Add Andrew as a Google test user and install the app on his phone.
2. Try the share extension and screenshot import on the iPhone: does the extension install
   with free signing and open the app? Does sharing from the Instagram app itself work?
   Does on-device text recognition misread "1 1/2" the way the Simulator did?
3. Then fix the known issue above.
4. Or work on the remaining extraction misses in `backend/eval/RESULTS.md`, adding real
   captions that go wrong to `backend/eval/captions.json`.
