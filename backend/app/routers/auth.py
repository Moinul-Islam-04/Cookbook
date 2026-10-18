"""/v1/auth: sign in with Google and get a device token.

This is the one /v1 route that doesn't need a bearer token: it's how a device gets one.
The user is found or created by `users.auth_subject` ("google:<sub>"), so signing in
again, on any device, reaches the same recipes.
"""

from typing import Annotated

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from app.auth import issue_token
from app.deps import get_db
from app.errors import ApiError
from app.google_auth import GoogleUnavailable, GoogleVerifier, InvalidGoogleToken
from app.models import User
from app.schemas import GoogleSignIn, SessionOut

router = APIRouter(prefix="/v1/auth", tags=["auth"])

DbSession = Annotated[Session, Depends(get_db)]


@router.post("/google", status_code=status.HTTP_201_CREATED, response_model=SessionOut)
def sign_in_with_google(body: GoogleSignIn, request: Request, db: DbSession) -> SessionOut:
    verifier: GoogleVerifier | None = request.app.state.google_verifier
    if verifier is None:
        raise ApiError(404, "not_found", "Google sign-in isn't turned on for this server.")
    try:
        claims = verifier.verify(body.id_token)
    except InvalidGoogleToken:
        raise ApiError(401, "unauthenticated", "Google sign-in couldn't be verified. Try signing in again.")
    except GoogleUnavailable:
        raise ApiError(503, "auth_unavailable", "Couldn't reach Google to check the sign-in. Try again.", retryable=True)

    subject = f"google:{claims['sub']}"
    db.execute(insert(User).values(auth_subject=subject).on_conflict_do_nothing(index_elements=["auth_subject"]))
    user_id = db.scalars(select(User.id).where(User.auth_subject == subject)).one()
    row, token = issue_token(db, user_id, body.device_name)
    db.commit()
    return SessionOut(token=token, token_id=row.id, expires_at=row.expires_at)
