"""Google sign-in: verify a Google ID token, then the caller gets an ordinary device token.

The app signs in with Google itself (OAuth with PKCE in ASWebAuthenticationSession) and
sends the ID token here once. We check its signature against Google's published keys,
plus issuer, audience (our client IDs) and expiry. After that, requests use the same
`ckb_` bearer tokens as paired devices, so nothing else in the API changes.
"""

from collections.abc import Callable
from typing import Any

import jwt

GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs"
GOOGLE_ISSUERS = ("accounts.google.com", "https://accounts.google.com")
# Allowance for clock differences between Google and this server.
LEEWAY_S = 30


class InvalidGoogleToken(Exception):
    """Forged, expired, for another app, or otherwise not a Google ID token for us."""


class GoogleUnavailable(Exception):
    """Google's signing keys couldn't be fetched (maps to 503, retryable)."""


class GoogleVerifier:
    def __init__(self, client_ids: list[str], signing_key: Callable[[str], Any] | None = None) -> None:
        self.client_ids = client_ids
        if signing_key is None:
            # Caches Google's keys and refetches when a token names an unknown key ID.
            jwks = jwt.PyJWKClient(GOOGLE_JWKS_URL, cache_keys=True, timeout=5)
            signing_key = lambda token: jwks.get_signing_key_from_jwt(token).key  # noqa: E731
        self._signing_key = signing_key

    def verify(self, id_token: str) -> dict[str, Any]:
        """The token's claims. `sub` is Google's stable, unique ID for the user."""
        try:
            key = self._signing_key(id_token)
        except jwt.PyJWKClientConnectionError as e:
            raise GoogleUnavailable() from e
        except (jwt.PyJWKClientError, jwt.InvalidTokenError) as e:
            raise InvalidGoogleToken() from e
        try:
            claims = jwt.decode(
                id_token,
                key,
                algorithms=["RS256"],
                audience=self.client_ids,
                leeway=LEEWAY_S,
                options={"require": ["iss", "aud", "exp", "iat", "sub"]},
            )
        except jwt.InvalidTokenError as e:
            raise InvalidGoogleToken() from e
        # Google issues tokens under two spellings of its issuer.
        if claims["iss"] not in GOOGLE_ISSUERS or not isinstance(claims["sub"], str) or not claims["sub"]:
            raise InvalidGoogleToken()
        return claims
