"""Recipe photos: upload, delete, and signed reads.

Upload order is chosen so a failure never leaves a row pointing at a missing object:
process -> store objects -> commit row. If the commit fails, the objects are deleted (and
anything a crash leaves behind is an orphan object, removed by `python -m app.cleanup`).
"""

import logging
import uuid
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, File, Query, Request, Response, UploadFile, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.deps import get_current_user_id, get_db
from app.errors import ApiError, not_found
from app.images import MAX_UPLOAD_BYTES, ImageSigner, InvalidImage, process_upload
from app.models import Recipe, RecipeImage
from app.schemas import FieldError, RecipeImageOut
from app.storage import ObjectStore, StorageError

log = logging.getLogger("cookbook")
router = APIRouter(tags=["images"])

DbSession = Annotated[Session, Depends(get_db)]
UserId = Annotated[uuid.UUID, Depends(get_current_user_id)]


def image_out(img: RecipeImage, signer: ImageSigner) -> RecipeImageOut:
    url, expires = signer.sign(img.object_key)
    thumb, _ = signer.sign(img.thumb_object_key)
    return RecipeImageOut(
        id=img.id, position=img.position, width=img.width, height=img.height,
        url=url, thumbnail_url=thumb, urls_expire_at=datetime.fromtimestamp(expires, UTC),
    )


def delete_objects(store: ObjectStore, keys: list[str]) -> None:
    """Best effort, after commit: a failure leaves an orphan for the cleanup command,
    never a readable photo (reads require the row, which is already gone)."""
    for key in keys:
        try:
            store.delete(key)
        except StorageError:
            log.warning("object delete failed; left for cleanup")


def _storage_unavailable() -> ApiError:
    return ApiError(503, "storage_unavailable", "Photo storage is unavailable. Try again shortly.", retryable=True)


def _owned_recipe(db: Session, user_id: uuid.UUID, recipe_id: uuid.UUID, *, lock: bool = False) -> Recipe:
    stmt = select(Recipe).where(Recipe.id == recipe_id, Recipe.user_id == user_id)
    if lock:
        stmt = stmt.with_for_update()
    recipe = db.scalars(stmt).one_or_none()
    if recipe is None:
        raise not_found()
    return recipe


@router.post("/v1/recipes/{recipe_id}/images", status_code=status.HTTP_201_CREATED, response_model=RecipeImageOut)
async def upload_image(
    recipe_id: uuid.UUID, request: Request, db: DbSession, user_id: UserId, file: Annotated[UploadFile, File()]
) -> RecipeImageOut:
    _owned_recipe(db, user_id, recipe_id)  # 404 before reading a large body
    data = await file.read(MAX_UPLOAD_BYTES + 1)
    try:
        processed = process_upload(data)
    except InvalidImage as e:
        raise ApiError(422, "invalid_image", str(e), field_errors=[FieldError(field="file", message=str(e))]) from None

    settings = request.app.state.settings
    store: ObjectStore = request.app.state.store
    base = f"users/{user_id}/recipes/{recipe_id}/{uuid.uuid4().hex}"
    keys = (f"{base}.jpg", f"{base}_thumb.jpg")
    try:
        store.put(keys[0], processed.full, "image/jpeg")
        store.put(keys[1], processed.thumb, "image/jpeg")
    except StorageError:
        delete_objects(store, list(keys))
        raise _storage_unavailable() from None

    try:
        _owned_recipe(db, user_id, recipe_id, lock=True)  # serializes position assignment
        count, last = db.execute(
            select(func.count(), func.max(RecipeImage.position)).where(RecipeImage.recipe_id == recipe_id)
        ).one()
        if count >= settings.max_images_per_recipe:
            raise ApiError(422, "too_many_images", f"A recipe can have at most {settings.max_images_per_recipe} photos.")
        img = RecipeImage(
            recipe_id=recipe_id, position=(last + 1) if last is not None else 0,
            object_key=keys[0], thumb_object_key=keys[1], content_type="image/jpeg",
            byte_size=len(processed.full), width=processed.width, height=processed.height,
        )
        db.add(img)
        db.commit()
    except BaseException:
        db.rollback()
        delete_objects(store, list(keys))
        raise
    return image_out(img, request.app.state.image_signer)


@router.delete("/v1/recipes/{recipe_id}/images/{image_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_image(recipe_id: uuid.UUID, image_id: uuid.UUID, request: Request, db: DbSession, user_id: UserId) -> Response:
    _owned_recipe(db, user_id, recipe_id, lock=True)
    img = db.scalars(
        select(RecipeImage).where(RecipeImage.id == image_id, RecipeImage.recipe_id == recipe_id)
    ).one_or_none()
    if img is None:
        raise not_found("photo")
    keys = [img.object_key, img.thumb_object_key]
    db.delete(img)
    db.commit()
    delete_objects(request.app.state.store, keys)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/v1/image-files/{key:path}", include_in_schema=False)
def read_image(
    key: str, request: Request, db: DbSession,
    exp: Annotated[int, Query()], sig: Annotated[str, Query(max_length=128)],
) -> Response:
    """The signature is the authorization: no bearer token, so AsyncImage can load it.
    The row must still exist, so a deleted photo stops loading even inside the TTL."""
    if not request.app.state.image_signer.verify(key, exp, sig):
        raise ApiError(403, "invalid_signature", "This photo link is invalid or has expired.")
    exists = db.scalar(
        select(func.count()).where(or_(RecipeImage.object_key == key, RecipeImage.thumb_object_key == key))
    )
    if not exists:
        raise not_found("photo")
    try:
        data = request.app.state.store.get(key)
    except StorageError:
        raise _storage_unavailable() from None
    remaining = max(0, exp - int(datetime.now(UTC).timestamp()))
    return Response(
        content=data, media_type="image/jpeg",
        headers={"Cache-Control": f"private, max-age={min(remaining, 3600)}"},
    )
