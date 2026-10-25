"""Post → draft extraction behind a provider-neutral adapter (stages 3 and 4 of ingestion).

    RawPost ─> extractor.extract() ─> raw JSON ─> validate_extraction() ─> DraftContent
"""

import logging
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from typing import TYPE_CHECKING

from app.extraction.base import (
    ExtractionError,
    ExtractionTimeout,
    Extractor,
    ProviderAccountProblem,
    ProviderUnreachable,
)
from app.extraction.fake import FakeExtractor, RuleBasedExtractor
from app.extraction.source import as_post
from app.extraction.validate import MalformedOutput, validate_extraction
from app.ingest import RawPost
from app.schemas import DraftContent

if TYPE_CHECKING:
    from app.config import Settings

log = logging.getLogger("cookbook")

# Bounded pool: a stalled provider can occupy at most this many threads.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="extract")
# Retry malformed output only with more time left than the slowest eval call took (9.4 s).
_MIN_RETRY_S = 10.0


def make_extractor(settings: "Settings") -> Extractor:
    provider = settings.extraction_provider
    if provider in ("fake", "rules"):
        return RuleBasedExtractor()
    if provider == "anthropic":
        if not settings.anthropic_api_key:
            raise RuntimeError("COOKBOOK_EXTRACTION_PROVIDER=anthropic needs COOKBOOK_ANTHROPIC_API_KEY.")
        from app.extraction.anthropic import AnthropicExtractor

        return AnthropicExtractor(
            settings.anthropic_api_key, settings.anthropic_model, settings.extraction_timeout_s
        )
    raise RuntimeError(
        f"Unknown COOKBOOK_EXTRACTION_PROVIDER {provider!r}; use 'fake' or 'anthropic'."
    )


def run_extraction(extractor: Extractor, post: RawPost | str, timeout_s: float) -> DraftContent:
    """Call the provider with a deadline, then validate its output against the post.

    Output that isn't the agreed JSON shape is retried once while time is left, then
    logged and raised. On timeout the worker thread can't be killed; it finishes in the
    background and its result is discarded. Real providers should also set their own
    client timeout.
    """
    post = as_post(post)
    deadline = time.monotonic() + timeout_s
    retried = False
    while True:
        future = _pool.submit(extractor.extract, post)
        try:
            raw = future.result(timeout=max(deadline - time.monotonic(), 0.0))
        except FutureTimeout:
            raise ExtractionTimeout() from None
        except (ExtractionError, ExtractionTimeout, MalformedOutput):
            raise
        except Exception as e:  # provider bug or SDK error: never leak details to clients
            raise ExtractionError(type(e).__name__) from e
        try:
            return validate_extraction(raw, post)
        except MalformedOutput as e:
            if retried or deadline - time.monotonic() < _MIN_RETRY_S:
                log.warning("malformed extraction output from %s (%s); giving up", extractor.version, e)
                raise
            log.warning("malformed extraction output from %s (%s); retrying once", extractor.version, e)
            retried = True


__all__ = [
    "ExtractionError",
    "ExtractionTimeout",
    "Extractor",
    "FakeExtractor",
    "MalformedOutput",
    "ProviderAccountProblem",
    "ProviderUnreachable",
    "RuleBasedExtractor",
    "make_extractor",
    "run_extraction",
]
