"""Instagram post identity for source links and duplicate warnings.

A link is only parsed, never fetched: this module makes no network calls. Only
recognized Instagram hosts and post paths are accepted; anything else is rejected
rather than guessed at (brief §4: "Do not guess identities for unsupported URL formats").
"""

import re
from dataclasses import dataclass
from urllib.parse import urlsplit

MAX_URL_LENGTH = 2048

_HOSTS = {"instagram.com", "www.instagram.com", "m.instagram.com"}
# /p/CODE, /reel/CODE, /reels/CODE, /tv/CODE, optionally after a /username/ segment.
# Shortcodes are URL-safe base64; real ones are 11 characters, private-post ones longer.
_PATH = re.compile(
    r"^/(?:[A-Za-z0-9._]{1,30}/)?(?P<kind>p|reel|reels|tv)/(?P<code>[A-Za-z0-9_-]{5,64})/?$"
)


class UnsupportedSourceUrl(ValueError):
    pass


@dataclass(frozen=True)
class InstagramPost:
    shortcode: str
    kind: str  # "p" or "reel"

    @property
    def post_key(self) -> str:
        """Duplicate-check identity. /p/X and /reel/X are the same post, so kind is excluded."""
        return f"instagram:{self.shortcode}"

    @property
    def canonical_url(self) -> str:
        return f"https://www.instagram.com/{self.kind}/{self.shortcode}/"


def parse_instagram_url(url: str) -> InstagramPost:
    """Normalize a pasted Instagram post or reel link.

    Ignores query strings (igsh=, utm_*), fragments, trailing slashes, the username
    segment and host variants. Rejects other hosts, credentials, ports and paths.
    """
    text = url.strip()
    if len(text) > MAX_URL_LENGTH:
        raise UnsupportedSourceUrl("The link is too long.")
    if "://" not in text:
        text = "https://" + text  # people paste "instagram.com/reel/..." without a scheme
    try:
        parts = urlsplit(text)
        port = parts.port
    except ValueError:
        raise UnsupportedSourceUrl("That doesn't look like a valid link.") from None

    host = (parts.hostname or "").lower().rstrip(".")
    if parts.scheme.lower() not in ("http", "https") or host not in _HOSTS:
        raise UnsupportedSourceUrl("Only Instagram post and reel links are supported.")
    if parts.username or parts.password or port is not None:
        raise UnsupportedSourceUrl("Only Instagram post and reel links are supported.")

    match = _PATH.match(parts.path)
    if not match:
        raise UnsupportedSourceUrl(
            "Use a link to a single Instagram post or reel (…/p/… or …/reel/…)."
        )
    # The shortcode identifies the post; kind only shapes the canonical link we store.
    kind = "reel" if match["kind"] in ("reel", "reels") else "p"
    return InstagramPost(shortcode=match["code"], kind=kind)
