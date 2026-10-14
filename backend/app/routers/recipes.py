"""/v1/recipes: manual recipe create, list/search, read, update, delete.

Every query is scoped to the current user's ID. Creates and source-link edits lock the
owner's users row, so a duplicate-post check and the insert that follows it can't
interleave with another save, and a retried Idempotency-Key waits for the first attempt.
"""

import base64
import hashlib
import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Header, Query, Response, status
from fastapi.responses import JSONResponse
from sqlalchemy import exists, or_, select, tuple_
from sqlalchemy.orm import Session

from app.deps import get_current_user_id, get_db
from app.drafts import owned_draft, reject_if_saved
from app.errors import ApiError, not_found
from app.models import IdempotencyKey, Recipe, RecipeIngredient, RecipeStep, User
from app.schemas import (
    FieldError,
    IngredientIn,
    IngredientOut,
    RecipeCreate,
    RecipeOut,
    RecipePage,
    RecipePatch,
    RecipeSummary,
    StepIn,
    StepOut,
)
from app.source_urls import InstagramPost, UnsupportedSourceUrl, parse_instagram_url

router = APIRouter(prefix="/v1/recipes", tags=["recipes"])

DbSession = Annotated[Session, Depends(get_db)]
UserId = Annotated[uuid.UUID, Depends(get_current_user_id)]

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100

# Printable ASCII, no spaces: UUIDs and similar client-generated tokens.
IdempotencyKeyHeader = Annotated[
    str | None,
    Header(alias="Idempotency-Key", min_length=1, max_length=255, pattern=r"^[\x21-\x7e]+$"),
]


# ---------- helpers ----------


def _format_quantity(q: Decimal) -> str:
    text = format(q.normalize(), "f")
    return text.rstrip("0").rstrip(".") if "." in text else text


def _raw_text(ing: IngredientIn) -> str:
    if ing.raw_text:
        return ing.raw_text
    parts = [_format_quantity(ing.quantity) if ing.quantity is not None else None, ing.unit, ing.name]
    return " ".join(p for p in parts if p)


def _ingredient_rows(items: list[IngredientIn]) -> list[RecipeIngredient]:
    # Positions come from array order, so clients can't send duplicates or gaps.
    return [
        RecipeIngredient(
            position=i, name=ing.name, quantity=ing.quantity, unit=ing.unit, raw_text=_raw_text(ing)
        )
        for i, ing in enumerate(items)
    ]


def _step_rows(items: list[StepIn]) -> list[RecipeStep]:
    return [RecipeStep(position=i, instruction=s.instruction) for i, s in enumerate(items)]


def _missing(recipe: Recipe) -> list[str]:
    missing = []
    if not recipe.ingredients:
        missing.append("ingredients")
    if not recipe.steps:
        missing.append("steps")
    return missing


def _to_out(recipe: Recipe) -> RecipeOut:
    return RecipeOut(
        id=recipe.id,
        title=recipe.title,
        notes=recipe.notes,
        source_kind=recipe.source_kind,
        source_url=recipe.source_url,
        created_at=recipe.created_at,
        updated_at=recipe.updated_at,
        version=recipe.version,
        ingredients=[IngredientOut.model_validate(i) for i in recipe.ingredients],
        steps=[StepOut.model_validate(s) for s in recipe.steps],
        missing=_missing(recipe),
    )


def _search_tag(term: str) -> str:
    # Short fingerprint of the search term, so a cursor can't be reused with a different q.
    return hashlib.sha256(term.encode()).hexdigest()[:12]


def _encode_cursor(recipe: Recipe, term: str) -> str:
    raw = json.dumps([recipe.created_at.isoformat(), str(recipe.id), _search_tag(term)]).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str, term: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        created_at_s, id_s, tag = json.loads(base64.urlsafe_b64decode(padded))
        created_at = datetime.fromisoformat(created_at_s)
        if created_at.tzinfo is None:
            raise ValueError("naive timestamp")
        if tag != _search_tag(term):
            raise ApiError(
                422,
                "invalid_request",
                "Some fields are invalid.",
                field_errors=[
                    FieldError(field="cursor", message="This cursor belongs to a different search.")
                ],
            )
        return created_at.astimezone(UTC), uuid.UUID(id_s)
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        raise ApiError(
            422,
            "invalid_request",
            "Some fields are invalid.",
            field_errors=[FieldError(field="cursor", message="Invalid pagination cursor.")],
        ) from None


def _lock_owner(db: Session, user_id: uuid.UUID) -> None:
    """Serialize this user's creates and source-link changes (held until commit)."""
    db.execute(select(User.id).where(User.id == user_id).with_for_update())


def _parse_source(url: str | None) -> InstagramPost | None:
    if url is None:
        return None
    try:
        return parse_instagram_url(url)
    except UnsupportedSourceUrl as e:
        raise ApiError(
            422,
            "invalid_request",
            "Some fields are invalid.",
            field_errors=[FieldError(field="source_url", message=str(e))],
        ) from None


def _reject_duplicate(
    db: Session, user_id: uuid.UUID, post_key: str, *, exclude: uuid.UUID | None = None
) -> None:
    stmt = (
        select(Recipe.id, Recipe.title)
        .where(Recipe.user_id == user_id, Recipe.source_post_key == post_key)
        .order_by(Recipe.created_at)
        .limit(1)
    )
    if exclude is not None:
        stmt = stmt.where(Recipe.id != exclude)
    existing = db.execute(stmt).first()
    if existing:
        raise ApiError(
            409,
            "duplicate_recipe",
            "You already saved this post.",
            details={"existing_recipe_id": str(existing.id), "existing_title": existing.title},
        )


def _request_hash(body: RecipeCreate) -> str:
    canonical = json.dumps(body.model_dump(mode="json"), sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def _like_pattern(term: str) -> str:
    escaped = term.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


def _owned_recipe(db: Session, user_id: uuid.UUID, recipe_id: uuid.UUID, *, lock: bool = False) -> Recipe:
    stmt = select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    if lock:
        stmt = stmt.with_for_update()
    recipe = db.scalars(stmt).one_or_none()
    if recipe is None:
        raise not_found()
    return recipe


# ---------- routes ----------


@router.post(
    "",
    status_code=status.HTTP_201_CREATED,
    response_model=RecipeOut,
    responses={409: {"description": "duplicate_recipe or idempotency_key_reused"}},
)
def create_recipe(
    body: RecipeCreate,
    db: DbSession,
    user_id: UserId,
    response: Response,
    idempotency_key: IdempotencyKeyHeader = None,
) -> RecipeOut | JSONResponse:
    post = _parse_source(body.source_url)
    _lock_owner(db, user_id)

    if idempotency_key is not None:
        request_hash = _request_hash(body)
        prior = db.get(IdempotencyKey, (user_id, idempotency_key))
        if prior is not None:
            if prior.request_hash != request_hash:
                raise ApiError(
                    409,
                    "idempotency_key_reused",
                    "This Idempotency-Key was already used for a different request.",
                )
            # A retry of a save that already happened: return the original result.
            headers = {"Idempotent-Replayed": "true"}
            if prior.recipe_id is not None:
                headers["Location"] = f"/v1/recipes/{prior.recipe_id}"
            return JSONResponse(
                status_code=prior.response_status, content=prior.response_body, headers=headers
            )

    draft = None
    if body.draft_id is not None:
        draft = owned_draft(db, user_id, body.draft_id, lock=True)
        reject_if_saved(draft)
        # A reviewed import must be a usable recipe (brief §3); manual ones may be partial.
        missing = [
            FieldError(field=f, message=f"Add at least one {f[:-1]} before saving.")
            for f in ("ingredients", "steps")
            if not getattr(body, f)
        ]
        if missing:
            raise ApiError(422, "invalid_request", "Some fields are invalid.", field_errors=missing)
        if post is None and "source_url" not in body.model_fields_set and draft.source_url:
            post = _parse_source(draft.source_url)

    if post is not None and not body.allow_duplicate:
        _reject_duplicate(db, user_id, post.post_key)

    now = datetime.now(UTC)
    recipe = Recipe(
        user_id=user_id,
        created_at=now,
        updated_at=now,
        title=body.title,
        notes=body.notes,
        source_kind="caption" if draft else "manual",
        source_text=draft.source_text if draft else None,
        source_url=post.canonical_url if post else None,
        source_post_key=post.post_key if post else None,
        ingredients=_ingredient_rows(body.ingredients),
        steps=_step_rows(body.steps),
    )
    db.add(recipe)
    db.flush()
    if draft is not None:
        draft.status = "saved"
        draft.saved_recipe_id = recipe.id
        draft.updated_at = now
    out = _to_out(recipe)
    if idempotency_key is not None:
        db.add(
            IdempotencyKey(
                user_id=user_id,
                key=idempotency_key,
                request_hash=request_hash,
                response_status=status.HTTP_201_CREATED,
                response_body=out.model_dump(mode="json"),
                recipe_id=recipe.id,
            )
        )
    db.commit()  # recipe, children, draft status and idempotency record: all or nothing
    response.headers["Location"] = f"/v1/recipes/{recipe.id}"
    return out


@router.get("", response_model=RecipePage)
def list_recipes(
    db: DbSession,
    user_id: UserId,
    limit: Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)] = DEFAULT_PAGE_SIZE,
    cursor: Annotated[str | None, Query(max_length=300)] = None,
    q: Annotated[str | None, Query(max_length=200)] = None,
) -> RecipePage:
    term = (q or "").strip()
    # Newest first; (created_at, id) keyset pagination is stable under inserts.
    stmt = (
        select(Recipe)
        .where(Recipe.user_id == user_id)
        .order_by(Recipe.created_at.desc(), Recipe.id.desc())
        .limit(limit + 1)
    )
    if term:
        # Case-insensitive substring on title or any ingredient name. EXISTS (not a JOIN)
        # so a recipe matching on several ingredients is still returned once.
        pattern = _like_pattern(term)
        stmt = stmt.where(
            or_(
                Recipe.title.ilike(pattern, escape="\\"),
                exists().where(
                    RecipeIngredient.recipe_id == Recipe.id,
                    RecipeIngredient.name.ilike(pattern, escape="\\"),
                ),
            )
        )
    if cursor:
        c_created, c_id = _decode_cursor(cursor, term)
        stmt = stmt.where(tuple_(Recipe.created_at, Recipe.id) < tuple_(c_created, c_id))
    rows = list(db.scalars(stmt))
    has_more = len(rows) > limit
    rows = rows[:limit]
    return RecipePage(
        items=[
            RecipeSummary(
                id=r.id,
                title=r.title,
                source_url=r.source_url,
                ingredient_count=len(r.ingredients),
                step_count=len(r.steps),
                missing=_missing(r),
                created_at=r.created_at,
                updated_at=r.updated_at,
            )
            for r in rows
        ],
        next_cursor=_encode_cursor(rows[-1], term) if has_more else None,
    )


@router.get("/{recipe_id}", response_model=RecipeOut)
def get_recipe(recipe_id: uuid.UUID, db: DbSession, user_id: UserId) -> RecipeOut:
    return _to_out(_owned_recipe(db, user_id, recipe_id))


@router.patch("/{recipe_id}", response_model=RecipeOut)
def update_recipe(recipe_id: uuid.UUID, body: RecipePatch, db: DbSession, user_id: UserId) -> RecipeOut:
    fields = body.model_fields_set
    if "source_url" in fields:
        post = _parse_source(body.source_url)
        _lock_owner(db, user_id)  # owner before recipe, the same order as everywhere else
    # Row lock serializes concurrent edits so the version check can't race.
    recipe = _owned_recipe(db, user_id, recipe_id, lock=True)
    if body.version != recipe.version:
        raise ApiError(
            409,
            "stale_version",
            "This recipe changed since you loaded it. Reload to see the latest version.",
            details={"current_version": recipe.version},
        )

    if "source_url" in fields:
        new_key = post.post_key if post else None
        if new_key is not None and new_key != recipe.source_post_key and not body.allow_duplicate:
            _reject_duplicate(db, user_id, new_key, exclude=recipe.id)
        recipe.source_url = post.canonical_url if post else None
        recipe.source_post_key = new_key
    if "title" in fields:
        recipe.title = body.title
    if "notes" in fields:
        recipe.notes = body.notes
    if "ingredients" in fields:
        recipe.ingredients.clear()
        db.flush()  # delete old rows before inserting new ones at the same positions
        recipe.ingredients.extend(_ingredient_rows(body.ingredients))
    if "steps" in fields:
        recipe.steps.clear()
        db.flush()
        recipe.steps.extend(_step_rows(body.steps))

    recipe.version += 1
    recipe.updated_at = datetime.now(UTC)
    db.commit()  # all field and child changes commit together or not at all
    return _to_out(recipe)


@router.delete("/{recipe_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_recipe(recipe_id: uuid.UUID, db: DbSession, user_id: UserId) -> Response:
    recipe = _owned_recipe(db, user_id, recipe_id)
    db.delete(recipe)  # ingredients and steps go with it (ON DELETE CASCADE)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
