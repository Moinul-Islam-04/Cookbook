"""RawPost: one social post, normalized. The boundary between the per-platform stages
(device fetch, then normalize) and the shared ones (extract, validate, save).

Everything after a RawPost is platform-neutral: adding a platform means a new link parser
in app/source_urls.py and a new normalizer module here, nothing else.
"""

from datetime import datetime

from pydantic import BaseModel, ConfigDict

from app.schemas import ImportDraftCreate
from app.source_urls import Platform, SourcePost


class RawPost(BaseModel):
    model_config = ConfigDict(frozen=True)

    # None when the user pasted text without a recognized link.
    platform: Platform | None
    post_id: str | None
    url: str | None  # canonical link, from app/source_urls.py
    author_handle: str | None
    caption: str
    transcript: str | None  # speech in the video, if the device or user supplied it
    top_comments: list[str]  # creators often post "recipe in the comments"
    media_urls: list[str]  # never downloaded
    posted_at: datetime | None


def build(
    payload: ImportDraftCreate,
    source: SourcePost | None,
    *,
    caption: str | None = None,
    author_handle: str | None = None,
    posted_at: datetime | None = None,
) -> RawPost:
    """The fields every platform fills the same way. What the device sent explicitly wins
    over what a normalizer read out of the text or link."""
    return RawPost(
        platform=source.platform if source else None,
        post_id=source.post_id if source else None,
        url=source.canonical_url if source else None,
        author_handle=payload.author_handle or author_handle or (source.author_handle if source else None),
        caption=caption if caption is not None else payload.source_text,
        transcript=payload.transcript,
        top_comments=list(payload.top_comments),
        media_urls=list(payload.media_urls),
        posted_at=payload.posted_at or posted_at,
    )


def normalize_pasted(payload: ImportDraftCreate, source: None = None) -> RawPost:
    """Text pasted without a link: no platform, no post identity."""
    return build(payload, None)
