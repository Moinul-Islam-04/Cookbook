import uuid
from collections.abc import Iterator

from fastapi import Request
from sqlalchemy.orm import Session

from app.config import DEV_USER_ID


def get_db(request: Request) -> Iterator[Session]:
    # Closing the session rolls back anything uncommitted, including after an error.
    with request.app.state.sessionmaker() as session:
        yield session


def get_current_user_id() -> uuid.UUID:
    """Identity for this request.

    Dev mode only: every request is the fixed local user. Real token verification
    (signature, issuer, audience, expiry) replaces this in Milestone 4. All recipe
    queries already filter by this ID, so ownership checks don't change shape later.
    """
    return DEV_USER_ID
