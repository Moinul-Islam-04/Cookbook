"""Stage 2 of ingestion: device payload → RawPost, per platform.

    device (fetch) ─> POST /v1/import-drafts ─> normalize() ─> RawPost ─> extraction (shared)
"""

from collections.abc import Callable

from app.ingest.instagram import normalize_instagram
from app.ingest.raw_post import RawPost, normalize_pasted
from app.ingest.tiktok import normalize_tiktok
from app.schemas import ImportDraftCreate
from app.source_urls import Platform, SourcePost

NORMALIZERS: dict[Platform, Callable[[ImportDraftCreate, SourcePost], RawPost]] = {
    "instagram": normalize_instagram,
    "tiktok": normalize_tiktok,
}


def normalize(payload: ImportDraftCreate, source: SourcePost | None) -> RawPost:
    """`source` is the payload's link, already parsed (app/source_urls.parse_source_url)."""
    if source is None:
        return normalize_pasted(payload)
    return NORMALIZERS[source.platform](payload, source)


__all__ = ["NORMALIZERS", "RawPost", "normalize"]
