"""Delete expired import drafts and old idempotency keys.

Run on a schedule (e.g. hourly cron/launchd):  python -m app.cleanup
Safe to re-run: each delete is one statement and only touches expired rows.
"""

from datetime import UTC, datetime, timedelta

from sqlalchemy import create_engine, delete
from sqlalchemy.orm import Session

from app.config import get_settings
from app.models import IdempotencyKey, ImportDraft

# Clients retry within seconds or minutes; a day is generous.
IDEMPOTENCY_KEY_TTL = timedelta(hours=24)


def cleanup(session: Session, now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(UTC)
    drafts = session.execute(delete(ImportDraft).where(ImportDraft.expires_at <= now))
    keys = session.execute(
        delete(IdempotencyKey).where(IdempotencyKey.created_at <= now - IDEMPOTENCY_KEY_TTL)
    )
    session.commit()
    return {"import_drafts": drafts.rowcount, "idempotency_keys": keys.rowcount}


def main() -> None:
    engine = create_engine(get_settings().database_url, connect_args={"options": "-c timezone=UTC"})
    with Session(engine) as session:
        print(cleanup(session))


if __name__ == "__main__":
    main()
