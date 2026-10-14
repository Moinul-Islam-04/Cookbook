import uuid
from collections.abc import Iterator
from typing import Annotated

from fastapi import Header, Request
from sqlalchemy.orm import Session

from app.auth import authenticate
from app.config import DEV_USER_ID
from app.errors import ApiError


def get_db(request: Request) -> Iterator[Session]:
    # Closing the session rolls back anything uncommitted, including after an error.
    with request.app.state.sessionmaker() as session:
        yield session


def get_current_user_id(
    request: Request, authorization: Annotated[str | None, Header()] = None
) -> uuid.UUID:
    """Identity for this request.

    dev:   every request is the owner (local only; no authentication).
    token: `Authorization: Bearer <device token>`; unknown, expired or revoked tokens get
           401. All queries already filter by this ID, so ownership checks are unchanged.
    """
    if request.app.state.settings.auth_mode == "dev":
        return DEV_USER_ID
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() == "bearer" and token:
        with request.app.state.sessionmaker() as session:
            user_id = authenticate(session, token.strip())
        if user_id is not None:
            return user_id
    raise ApiError(
        401,
        "unauthenticated",
        "This device isn't signed in. Pair it in Settings with a code from `python -m app.tokens create`.",
    )
