"""Delete expired import drafts, the raw posts nothing refers to, and old idempotency keys.

Run on a schedule (e.g. hourly cron/launchd):  python -m app.cleanup
Safe to re-run: each delete is one statement and only touches expired rows.
"""

from datetime import UTC, datetime, timedelta

from sqlalchemy import create_engine, delete, exists
from sqlalchemy.orm import Session

from sqlalchemy import select

from app.config import get_settings
from app.models import IdempotencyKey, ImportDraft, RawPostRow, Recipe, RecipeImage
from app.storage import ObjectStore, StorageError, make_store

# Clients retry within seconds or minutes; a day is generous.
IDEMPOTENCY_KEY_TTL = timedelta(hours=24)
# Objects younger than this may belong to an upload whose row is about to commit.
ORPHAN_GRACE = timedelta(hours=1)


def cleanup(session: Session, now: datetime | None = None) -> dict[str, int]:
    now = now or datetime.now(UTC)
    drafts = session.execute(delete(ImportDraft).where(ImportDraft.expires_at <= now))
    # After the drafts: a post whose draft just expired unsaved goes too. A draft and its
    # post are inserted in one transaction, so there's no in-flight post to spare.
    posts = session.execute(
        delete(RawPostRow).where(
            ~exists().where(ImportDraft.raw_post_id == RawPostRow.id),
            ~exists().where(Recipe.raw_post_id == RawPostRow.id),
        )
    )
    keys = session.execute(
        delete(IdempotencyKey).where(IdempotencyKey.created_at <= now - IDEMPOTENCY_KEY_TTL)
    )
    session.commit()
    return {"import_drafts": drafts.rowcount, "raw_posts": posts.rowcount, "idempotency_keys": keys.rowcount}


def cleanup_orphan_objects(session: Session, store: ObjectStore, now: datetime | None = None) -> int:
    """Delete stored photos with no recipe_images row: failed deletes, interrupted uploads."""
    now = now or datetime.now(UTC)
    known = set(session.scalars(select(RecipeImage.object_key))) | set(
        session.scalars(select(RecipeImage.thumb_object_key))
    )
    deleted = 0
    for obj in store.list("users/"):
        if obj.key not in known and now - obj.last_modified > ORPHAN_GRACE:
            try:
                store.delete(obj.key)
                deleted += 1
            except StorageError:
                pass  # retried on the next run
    return deleted


def main() -> None:
    settings = get_settings()
    engine = create_engine(settings.database_url, connect_args={"options": "-c timezone=UTC"})
    with Session(engine) as session:
        result = cleanup(session)
        result["orphan_objects"] = cleanup_orphan_objects(session, make_store(settings))
        print(result)


if __name__ == "__main__":
    main()
