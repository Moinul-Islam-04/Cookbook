"""Manage device tokens (auth_mode=token).

    python -m app.tokens create --name "Mo's iPhone" --server https://my-mac.tailnet.ts.net
    python -m app.tokens list
    python -m app.tokens revoke <token-id>

`create` prints the token and a pairing code once. Paste the pairing code in the app's
Settings (Universal Clipboard: copy on the Mac, paste on the iPhone).
"""

import argparse
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import create_engine, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.auth import issue_token, pairing_code
from app.config import DEV_USER_ID, get_settings
from app.models import ApiToken, User


def main() -> None:
    ap = argparse.ArgumentParser(prog="python -m app.tokens")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("create")
    c.add_argument("--name", required=True)
    c.add_argument("--server", default="http://127.0.0.1:8000", help="URL the device will use")
    c.add_argument("--days", type=int, default=365)
    sub.add_parser("list")
    r = sub.add_parser("revoke")
    r.add_argument("token_id", type=uuid.UUID)
    args = ap.parse_args()

    engine = create_engine(get_settings().database_url, connect_args={"options": "-c timezone=UTC"})
    with Session(engine) as s:
        if args.cmd == "create":
            s.execute(insert(User).values(id=DEV_USER_ID).on_conflict_do_nothing())
            row, token = issue_token(s, DEV_USER_ID, args.name, timedelta(days=args.days))
            s.commit()
            print(f"Created token {row.id} ({row.name}), expires {row.expires_at:%Y-%m-%d}.")
            print("Shown once; only a hash is stored.\n")
            print(f"Pairing code (paste in the app's Settings):\n{pairing_code(args.server, token)}\n")
            print(f"Raw token (for curl: -H 'Authorization: Bearer ...'):\n{token}")
        elif args.cmd == "list":
            for t in s.scalars(select(ApiToken).order_by(ApiToken.created_at)):
                state = "revoked" if t.revoked_at else "expired" if t.expires_at <= datetime.now(UTC) else "active"
                used = f"{t.last_used_at:%Y-%m-%d %H:%M}" if t.last_used_at else "never"
                print(f"{t.id}  {state:8} {t.name!r:24} created {t.created_at:%Y-%m-%d}  last used {used}")
        else:
            t = s.get(ApiToken, args.token_id)
            if t is None:
                raise SystemExit("No such token.")
            t.revoked_at = datetime.now(UTC)
            s.commit()
            print(f"Revoked {t.id} ({t.name}).")


if __name__ == "__main__":
    main()
