"""/v1/recipes: manual recipe create, list, read, update, delete.

Every query is scoped to the current user's ID. Search (q), duplicate-post
warnings and idempotency keys are Milestone 2 and intentionally absent here.
"""

import base64
import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status
from sqlalchemy import select, tuple_
from sqlalchemy.orm import Session

from app.deps import get_current_user_id, get_db
from app.errors import ApiError, not_found
from app.models import Recipe, RecipeIngredient, RecipeStep
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

router = APIRouter(prefix="/v1/recipes", tags=["recipes"])

DbSession = Annotated[Session, Depends(get_db)]
UserId = Annotated[uuid.UUID, Depends(get_current_user_id)]

DEFAULT_PAGE_SIZE = 20
MAX_PAGE_SIZE = 100


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


def _encode_cursor(recipe: Recipe) -> str:
    raw = json.dumps([recipe.created_at.isoformat(), str(recipe.id)]).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def _decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        created_at_s, id_s = json.loads(base64.urlsafe_b64decode(padded))
        created_at = datetime.fromisoformat(created_at_s)
        if created_at.tzinfo is None:
            raise ValueError("naive timestamp")
        return created_at.astimezone(UTC), uuid.UUID(id_s)
    except (ValueError, TypeError, json.JSONDecodeError, UnicodeDecodeError):
        raise ApiError(
            422,
            "invalid_request",
            "Some fields are invalid.",
            field_errors=[FieldError(field="cursor", message="Invalid pagination cursor.")],
        ) from None


def _owned_recipe(db: Session, user_id: uuid.UUID, recipe_id: uuid.UUID, *, lock: bool = False) -> Recipe:
    stmt = select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    if lock:
        stmt = stmt.with_for_update()
    recipe = db.scalars(stmt).one_or_none()
    if recipe is None:
        raise not_found()
    return recipe


# ---------- routes ----------


@router.post("", status_code=status.HTTP_201_CREATED, response_model=RecipeOut)
def create_recipe(body: RecipeCreate, db: DbSession, user_id: UserId, response: Response) -> RecipeOut:
    now = datetime.now(UTC)
    recipe = Recipe(
        user_id=user_id,
        created_at=now,
        updated_at=now,
        title=body.title,
        notes=body.notes,
        source_kind="manual",
        ingredients=_ingredient_rows(body.ingredients),
        steps=_step_rows(body.steps),
    )
    db.add(recipe)
    db.commit()  # recipe and all children commit together or not at all
    response.headers["Location"] = f"/v1/recipes/{recipe.id}"
    return _to_out(recipe)


@router.get("", response_model=RecipePage)
def list_recipes(
    db: DbSession,
    user_id: UserId,
    limit: Annotated[int, Query(ge=1, le=MAX_PAGE_SIZE)] = DEFAULT_PAGE_SIZE,
    cursor: Annotated[str | None, Query(max_length=200)] = None,
) -> RecipePage:
    # Newest first; (created_at, id) keyset pagination is stable under inserts.
    stmt = (
        select(Recipe)
        .where(Recipe.user_id == user_id)
        .order_by(Recipe.created_at.desc(), Recipe.id.desc())
        .limit(limit + 1)
    )
    if cursor:
        c_created, c_id = _decode_cursor(cursor)
        stmt = stmt.where(tuple_(Recipe.created_at, Recipe.id) < tuple_(c_created, c_id))
    rows = list(db.scalars(stmt))
    has_more = len(rows) > limit
    rows = rows[:limit]
    return RecipePage(
        items=[
            RecipeSummary(
                id=r.id,
                title=r.title,
                ingredient_count=len(r.ingredients),
                step_count=len(r.steps),
                missing=_missing(r),
                created_at=r.created_at,
                updated_at=r.updated_at,
            )
            for r in rows
        ],
        next_cursor=_encode_cursor(rows[-1]) if has_more else None,
    )


@router.get("/{recipe_id}", response_model=RecipeOut)
def get_recipe(recipe_id: uuid.UUID, db: DbSession, user_id: UserId) -> RecipeOut:
    return _to_out(_owned_recipe(db, user_id, recipe_id))


@router.patch("/{recipe_id}", response_model=RecipeOut)
def update_recipe(recipe_id: uuid.UUID, body: RecipePatch, db: DbSession, user_id: UserId) -> RecipeOut:
    # Row lock serializes concurrent edits so the version check can't race.
    recipe = _owned_recipe(db, user_id, recipe_id, lock=True)
    if body.version != recipe.version:
        raise ApiError(
            409,
            "stale_version",
            "This recipe changed since you loaded it. Reload to see the latest version.",
            details={"current_version": recipe.version},
        )

    fields = body.model_fields_set
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
