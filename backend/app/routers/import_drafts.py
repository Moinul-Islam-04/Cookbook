"""/v1/import-drafts: pasted caption → validated, editable draft.

Creating a draft runs the configured extraction provider with a deadline, then
validates its output against the caption (app/extraction/validate.py). Drafts are only
ever turned into recipes by an explicit POST /v1/recipes with draft_id.
"""

import logging
import uuid
from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy import select
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
from app.models import ImportDraft, Recipe
from app.routers.recipes import _parse_source
from app.schemas import (
    DraftContent,
    DraftWarning,
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
        extraction_version=draft.extraction_version,
        version=draft.version,
        saved_recipe_id=draft.saved_recipe_id,
        created_at=draft.created_at,
        updated_at=draft.updated_at,
        expires_at=draft.expires_at,
    )


@router.post("", status_code=status.HTTP_201_CREATED, response_model=ImportDraftOut)
def create_draft(body: ImportDraftCreate, request: Request, db: DbSession, user_id: UserId) -> ImportDraftOut:
    post = _parse_source(body.source_url)
    settings = request.app.state.settings
    extractor = request.app.state.extractor

    # Extraction runs before any DB write, so a provider failure leaves nothing behind.
    # The client still has the caption and can retry or enter the recipe manually.
    try:
        content = run_extraction(extractor, body.source_text, settings.extraction_timeout_s)
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
    draft = ImportDraft(
        user_id=user_id,
        source_text=body.source_text,
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
