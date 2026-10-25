"""/v1/import-drafts: what the device read from a post → validated, editable draft.

Creating a draft normalizes the request into a RawPost (app/ingest), runs the configured
extraction provider with a deadline, then validates its output against the post
(app/extraction/validate.py). The RawPost is stored alongside the draft. Drafts are only
ever turned into recipes by an explicit POST /v1/recipes with draft_id.
"""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.deps import get_current_user_id, get_db
from app.drafts import owned_draft, reject_if_saved
from app.errors import ApiError
from app.extraction import (
    ExtractionError,
    ExtractionTimeout,
    MalformedOutput,
    ProviderAccountProblem,
    ProviderUnreachable,
    run_extraction,
)
from app.ingest import normalize
from app.models import ImportDraft, RawPostRow, Recipe
from app.routers.recipes import _parse_source
from app.schemas import (
    DraftContent,
    DraftWarning,
    FieldError,
    ImportDraftCreate,
    ImportDraftOut,
    ImportDraftPatch,
    IngredientDraft,
    StepDraft,
)

log = logging.getLogger("cookbook")

router = APIRouter(prefix="/v1/import-drafts", tags=["import drafts"])

DbSession = Annotated[Session, Depends(get_db)]
UserId = Annotated[uuid.UUID, Depends(get_current_user_id)]


def _to_out(draft: ImportDraft) -> ImportDraftOut:
    content = DraftContent.model_validate(draft.content)
    return ImportDraftOut(
        id=draft.id,
        status=draft.status,
        source_text=draft.source_text,
        source_url=draft.source_url,
        title=content.title,
        ingredients=content.ingredients,
        steps=content.steps,
        warnings=content.warnings,
        servings=content.servings,
        sub_recipes=content.sub_recipes,
        extraction_version=draft.extraction_version,
        version=draft.version,
        saved_recipe_id=draft.saved_recipe_id,
        created_at=draft.created_at,
        updated_at=draft.updated_at,
        expires_at=draft.expires_at,
    )


def _retry_after(db: Session, user_id: uuid.UUID | None, window: timedelta, limit: int, now: datetime) -> int | None:
    """Seconds until fewer than `limit` drafts were created in the window, or None if already
    under it. Counts this user's drafts, or everyone's when user_id is None."""
    since = now - window
    stmt = select(ImportDraft.created_at).where(ImportDraft.created_at > since)
    if user_id is not None:
        stmt = stmt.where(ImportDraft.user_id == user_id)
    total = db.scalar(select(func.count()).select_from(stmt.subquery()))
    if total < limit:
        return None
    # Once this draft leaves the window, the count drops below the limit.
    freed_by = db.scalar(stmt.order_by(ImportDraft.created_at).offset(total - limit).limit(1))
    return max(1, int((freed_by + window - now).total_seconds()) + 1)


def check_import_limits(db: Session, settings, user_id: uuid.UUID) -> None:
    """429 before the extractor is called. Concurrent requests can each pass the check
    before any of them inserts, so a burst may overshoot by the number in flight."""
    now = datetime.now(UTC)
    hour, day = timedelta(hours=1), timedelta(hours=24)
    wait = _retry_after(db, None, day, settings.import_limit_global_per_day, now)
    if wait is not None:
        log.warning("global daily import limit reached")
        raise ApiError(429, "rate_limited", "Recipe reading is paused for everyone because today's limit was reached. You can still enter the recipe manually.", retryable=True, headers={"Retry-After": str(wait)})
    for window, limit, period in ((hour, settings.import_limit_per_hour, "hour"), (day, settings.import_limit_per_day, "day")):
        wait = _retry_after(db, user_id, window, limit, now)
        if wait is not None:
            raise ApiError(429, "rate_limited", f"You've read {limit} recipes in the last {period}, the most allowed. Try again later, or enter the recipe manually now.", retryable=True, headers={"Retry-After": str(wait)})


@router.post("", status_code=status.HTTP_201_CREATED, response_model=ImportDraftOut)
def create_draft(body: ImportDraftCreate, request: Request, db: DbSession, user_id: UserId) -> ImportDraftOut:
    post = _parse_source(body.source_url)
    raw = normalize(body, post)
    settings = request.app.state.settings
    extractor = request.app.state.extractor
    check_import_limits(db, settings, user_id)
    db.rollback()  # end the read-only transaction; don't hold it open during extraction

    # Extraction runs before any DB write, so a provider failure leaves nothing behind.
    # The client still has the caption and can retry or enter the recipe manually.
    try:
        content = run_extraction(extractor, raw, settings.extraction_timeout_s)
    except ExtractionTimeout:
        raise ApiError(504, "extraction_timeout", "Reading the caption took too long. Try again, or enter it manually.", retryable=True) from None
    except MalformedOutput:
        raise ApiError(502, "extraction_failed", "Couldn't read a recipe from the extractor's response. Try again, or enter it manually.", retryable=True) from None
    except ProviderUnreachable:
        raise ApiError(503, "extraction_unreachable", "Couldn't reach the recipe reader. Check that the server has internet, then try again, or enter the recipe manually.", retryable=True) from None
    except ProviderAccountProblem as e:
        # The owner has to act (top up credit or fix COOKBOOK_ANTHROPIC_API_KEY); say so in the log.
        log.warning("extraction provider rejected the account (%s): check credit and API key", e)
        raise ApiError(503, "extraction_account", "Recipe reading is paused because the recipe reader's account needs attention, for example it's out of credit. You can still enter the recipe manually.", retryable=False) from None
    except ExtractionError:
        raise ApiError(503, "extraction_unavailable", "Recipe extraction is unavailable right now. You can still enter the recipe manually.", retryable=True) from None
    # Kept before the duplicate_post warning is added: that comes from the user's cookbook,
    # not the model.
    extracted = content.model_dump(mode="json")

    if post is not None:
        # A heads-up only; the save itself enforces the duplicate rule (409).
        existing = db.execute(
            select(Recipe.id, Recipe.title)
            .where(Recipe.user_id == user_id, Recipe.source_post_key == post.post_key)
            .order_by(Recipe.created_at)
            .limit(1)
        ).first()
        if existing:
            content.warnings.insert(
                0,
                DraftWarning(
                    code="duplicate_post",
                    message=f"You already saved this post as “{existing.title}”.",
                    field="source_url",
                    recipe_id=existing.id,
                ),
            )

    now = datetime.now(UTC)
    raw_row = RawPostRow(user_id=user_id, created_at=now, **raw.model_dump())
    draft = ImportDraft(
        user_id=user_id,
        raw_post=raw_row,
        source_text=raw.caption,
        source_url=post.canonical_url if post else None,
        source_post_key=post.post_key if post else None,
        content=content.model_dump(mode="json"),
        extracted_content=extracted,
        extraction_version=extractor.version,
        created_at=now,
        updated_at=now,
        expires_at=now + timedelta(hours=settings.draft_ttl_hours),
    )
    db.add(draft)
    db.commit()
    return _to_out(draft)


@router.get("/{draft_id}", response_model=ImportDraftOut)
def get_draft(draft_id: uuid.UUID, db: DbSession, user_id: UserId) -> ImportDraftOut:
    return _to_out(owned_draft(db, user_id, draft_id))


@router.patch("/{draft_id}", response_model=ImportDraftOut)
def update_draft(draft_id: uuid.UUID, body: ImportDraftPatch, db: DbSession, user_id: UserId) -> ImportDraftOut:
    draft = owned_draft(db, user_id, draft_id, lock=True)
    reject_if_saved(draft)
    if body.version != draft.version:
        raise ApiError(
            409,
            "stale_version",
            "This draft changed since you loaded it. Reload to see the latest version.",
            details={"current_version": draft.version},
        )
    content = DraftContent.model_validate(draft.content)
    fields = body.model_fields_set
    bad = [
        FieldError(field=f"{name}.{i}.sub_recipe", message="No sub-recipe with this index in the draft.")
        for name in ("ingredients", "steps") if name in fields
        for i, row in enumerate(getattr(body, name))
        if row.sub_recipe is not None and row.sub_recipe >= len(content.sub_recipes)
    ]
    if bad:
        raise ApiError(422, "invalid_request", "Some fields are invalid.", field_errors=bad)
    if "title" in fields:
        content.title = body.title
    if "ingredients" in fields:
        content.ingredients = [
            IngredientDraft(**i.model_dump(), review_reasons=[]) for i in body.ingredients
        ]
    if "steps" in fields:
        content.steps = [StepDraft(**s.model_dump(), review_reasons=[]) for s in body.steps]
    draft.content = content.model_dump(mode="json")
    draft.version += 1
    draft.updated_at = datetime.now(UTC)
    db.commit()
    return _to_out(draft)
