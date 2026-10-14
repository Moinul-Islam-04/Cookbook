"""Device tokens: opaque random bearer tokens, stored hashed, expiring and revocable.

Chosen over managed auth for a single-user, self-hosted backend (docs/DECISIONS.md):
no third-party account or cost, and nothing to verify but a hash lookup. A forged token
can't match a stored hash; an expired or revoked one is rejected the same way.
"""

import base64
import hashlib
import json
import secrets
import uuid
from datetime import UTC, datetime, timedelta

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.models import ApiToken

TOKEN_PREFIX = "ckb_"
PAIRING_PREFIX = "cookbook-pair:"
DEFAULT_LIFETIME = timedelta(days=365)
# Writing last_used_at on every request is wasteful; once a minute is plenty.
LAST_USED_RESOLUTION = timedelta(minutes=1)


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def issue_token(
    session: Session, user_id: uuid.UUID, name: str, lifetime: timedelta = DEFAULT_LIFETIME
) -> tuple[ApiToken, str]:
    """Create a token. The plaintext is returned once and never stored."""
    token = TOKEN_PREFIX + secrets.token_urlsafe(32)
    now = datetime.now(UTC)
    row = ApiToken(
        user_id=user_id, name=name, token_hash=hash_token(token), created_at=now, expires_at=now + lifetime
    )
    session.add(row)
    session.flush()
    return row, token


def authenticate(session: Session, token: str) -> uuid.UUID | None:
    """The token's user, or None if it's unknown, expired or revoked."""
    if not token.startswith(TOKEN_PREFIX) or len(token) > 200:
        return None
    now = datetime.now(UTC)
    row = session.scalars(select(ApiToken).where(ApiToken.token_hash == hash_token(token))).one_or_none()
    if row is None or row.revoked_at is not None or row.expires_at <= now:
        return None
    if row.last_used_at is None or now - row.last_used_at > LAST_USED_RESOLUTION:
        session.execute(update(ApiToken).where(ApiToken.id == row.id).values(last_used_at=now))
        session.commit()
    return row.user_id


def pairing_code(server_url: str, token: str) -> str:
    """One string to paste on the phone: the server address and the token together."""
    payload = json.dumps({"server": server_url, "token": token}, separators=(",", ":"))
    return PAIRING_PREFIX + base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")
