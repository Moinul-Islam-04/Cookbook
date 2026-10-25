"""Instagram normalizer: what the device read from a post → RawPost.

Fetching happens on the user's device (the in-app browser, a paste or screenshots); the
server never contacts Instagram (DECISIONS 2026-10-14). Besides a plain caption, the
device or user may hand over the page's preview text, which wraps the caption:

    og:description  1,234 likes, 56 comments - chef.ann on May 1, 2026: "caption".
    og:title        Chef Ann on Instagram: “caption”

The iOS app already unwraps these (InstagramPageText.quotedCaption); this does the same
on the server for pasted preview text, and keeps the handle and date it names.
"""

import re
from datetime import UTC, datetime

from app.ingest.raw_post import RawPost, build
from app.schemas import ImportDraftCreate
from app.source_urls import SourcePost

_COUNT = r"[\d.,]+[KkMm]?"
_OG_DESCRIPTION = re.compile(
    rf"^{_COUNT} likes?, {_COUNT} comments? - (?P<handle>[A-Za-z0-9._]{{1,30}}) on "
    r"(?P<date>[A-Z][a-z]+ \d{1,2}, \d{4}): [\"“](?P<caption>.*?)[\"”]\.?$",
    re.S,
)
_OG_TITLE = re.compile(r"^[^\n]{1,100}? on Instagram: [\"“](?P<caption>.*?)[\"”]\.?$", re.S)


def unwrap_preview(text: str) -> tuple[str, str | None, datetime | None]:
    """(caption, handle, posted_at) from preview text; the text itself if it isn't one.
    posted_at has day precision: the preview names a date, not a time."""
    text = text.strip()
    if m := _OG_DESCRIPTION.match(text):
        try:
            posted = datetime.strptime(m["date"], "%B %d, %Y").replace(tzinfo=UTC)
        except ValueError:  # not an English month name
            posted = None
        return m["caption"].strip(), m["handle"], posted
    if m := _OG_TITLE.match(text):
        return m["caption"].strip(), None, None  # the title names a display name, not a handle
    return text, None, None


def normalize_instagram(payload: ImportDraftCreate, source: SourcePost) -> RawPost:
    caption, handle, posted_at = unwrap_preview(payload.source_text)
    if not caption:  # preview with an empty caption: keep what was sent
        caption = payload.source_text
    return build(payload, source, caption=caption, author_handle=handle, posted_at=posted_at)
