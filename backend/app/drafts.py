"""Draft lookups shared by the import-drafts and recipes routers."""

import uuid
from datetime import UTC, datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.errors import ApiError, not_found
from app.models import ImportDraft


def owned_draft(
    db: Session, user_id: uuid.UUID, draft_id: uuid.UUID, *, lock: bool = False
) -> ImportDraft:
    stmt = select(ImportDraft).where(ImportDraft.id == draft_id, ImportDraft.user_id == user_id)
    if lock:
        stmt = stmt.with_for_update()
    draft = db.scalars(stmt).one_or_none()
    if draft is None:
        raise not_found("draft")
    if draft.expires_at <= datetime.now(UTC):
        raise ApiError(410, "draft_expired", "This draft expired. Paste the caption again to start over.")
    return draft


def reject_if_saved(draft: ImportDraft) -> None:
    if draft.status == "saved":
        raise ApiError(
            409,
            "draft_already_saved",
            "This draft was already saved as a recipe.",
            details={"saved_recipe_id": str(draft.saved_recipe_id) if draft.saved_recipe_id else None},
        )
