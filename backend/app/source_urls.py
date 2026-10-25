"""Instagram and TikTok post identity for source links and duplicate warnings.

A link is only parsed, never fetched: this module makes no network calls. Only
recognized hosts and post paths are accepted; anything else is rejected rather than
guessed at (brief §4: "Do not guess identities for unsupported URL formats").
"""

import re
from dataclasses import dataclass
from typing import Literal
from urllib.parse import SplitResult, urlsplit

MAX_URL_LENGTH = 2048

Platform = Literal["instagram", "tiktok"]

_INSTAGRAM_HOSTS = {"instagram.com", "www.instagram.com", "m.instagram.com"}
# /p/CODE, /reel/CODE, /reels/CODE, /tv/CODE, optionally after a /username/ segment.
# Shortcodes are URL-safe base64; real ones are 11 characters, private-post ones longer.
_INSTAGRAM_PATH = re.compile(
    r"^/(?:(?P<handle>[A-Za-z0-9._]{1,30})/)?(?P<kind>p|reel|reels|tv)/(?P<code>[A-Za-z0-9_-]{5,64})/?$"
)

_TIKTOK_HOSTS = {"tiktok.com", "www.tiktok.com", "m.tiktok.com"}
# Short links redirect to the real post; following them would mean fetching TikTok.
_TIKTOK_SHORT_HOSTS = {"vm.tiktok.com", "vt.tiktok.com"}
# /@handle/video/ID and /@handle/photo/ID. Video IDs are 19 digits today; allow some slack.
_TIKTOK_PATH = re.compile(r"^/@(?P<handle>[A-Za-z0-9._]{1,30})/(?P<kind>video|photo)/(?P<code>\d{15,22})/?$")

_UNSUPPORTED = "Only Instagram and TikTok post links are supported."


class UnsupportedSourceUrl(ValueError):
    pass


@dataclass(frozen=True)
class SourcePost:
    platform: Platform
    post_id: str  # Instagram shortcode or TikTok numeric ID
    kind: str  # "p" or "reel" (Instagram), "video" or "photo" (TikTok)
    author_handle: str | None = None  # only when the link names it

    @property
    def post_key(self) -> str:
        """Duplicate-check identity. /p/X and /reel/X are the same post, so kind is excluded."""
        return f"{self.platform}:{self.post_id}"

    @property
    def canonical_url(self) -> str:
        if self.platform == "tiktok":
            return f"https://www.tiktok.com/@{self.author_handle}/{self.kind}/{self.post_id}"
        return f"https://www.instagram.com/{self.kind}/{self.post_id}/"


# Kept for the name used across the codebase before TikTok links were accepted.
InstagramPost = SourcePost


def _split(url: str) -> tuple[SplitResult, str]:
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
    if parts.scheme.lower() not in ("http", "https") or parts.username or parts.password or port is not None:
        raise UnsupportedSourceUrl(_UNSUPPORTED)
    return parts, (parts.hostname or "").lower().rstrip(".")


def parse_source_url(url: str) -> SourcePost:
    """Normalize a pasted Instagram post/reel or TikTok video/photo link.

    Ignores query strings (igsh=, utm_*, is_from_webapp=), fragments, trailing slashes
    and host variants. Rejects other hosts, credentials, ports and paths.
    """
    parts, host = _split(url)
    if host in _INSTAGRAM_HOSTS:
        return _instagram(parts)
    if host in _TIKTOK_HOSTS or host in _TIKTOK_SHORT_HOSTS:
        return _tiktok(parts, host)
    raise UnsupportedSourceUrl(_UNSUPPORTED)


def parse_instagram_url(url: str) -> SourcePost:
    """Like parse_source_url, but only Instagram links are accepted."""
    parts, host = _split(url)
    if host not in _INSTAGRAM_HOSTS:
        raise UnsupportedSourceUrl("Only Instagram post and reel links are supported.")
    return _instagram(parts)


def _instagram(parts: SplitResult) -> SourcePost:
    match = _INSTAGRAM_PATH.match(parts.path)
    if not match:
        raise UnsupportedSourceUrl(
            "Use a link to a single Instagram post or reel (…/p/… or …/reel/…)."
        )
    # The shortcode identifies the post; kind only shapes the canonical link we store.
    kind = "reel" if match["kind"] in ("reel", "reels") else "p"
    return SourcePost("instagram", match["code"], kind, match["handle"])


def _tiktok(parts: SplitResult, host: str) -> SourcePost:
    if host in _TIKTOK_SHORT_HOSTS or parts.path.startswith("/t/"):
        raise UnsupportedSourceUrl(
            "Short TikTok links can't be read. Open the post in TikTok's app or website and copy its full link (…/@name/video/…)."
        )
    match = _TIKTOK_PATH.match(parts.path)
    if not match:
        raise UnsupportedSourceUrl("Use a link to a single TikTok post (…/@name/video/…).")
    return SourcePost("tiktok", match["code"], match["kind"], match["handle"])
