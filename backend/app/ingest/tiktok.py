"""TikTok normalizer: what the device read from a post → RawPost.

As with Instagram, fetching happens on the user's device; the server never contacts
TikTok. The handle comes from the link (/@handle/video/ID). No TikTok page or preview
format has been verified yet (that needs the iOS in-app browser for TikTok), so the
caption is taken as sent.
"""

from app.ingest.raw_post import RawPost, build
from app.schemas import ImportDraftCreate
from app.source_urls import SourcePost


def normalize_tiktok(payload: ImportDraftCreate, source: SourcePost) -> RawPost:
    return build(payload, source)
