"""Caption → draft extraction behind a provider-neutral adapter."""

from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout

from app.extraction.base import ExtractionError, ExtractionTimeout, Extractor
from app.extraction.fake import FakeExtractor, RuleBasedExtractor
from app.extraction.validate import MalformedOutput, validate_extraction
from app.schemas import DraftContent

# Bounded pool: a stalled provider can occupy at most this many threads.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="extract")


def make_extractor(provider: str) -> Extractor:
    if provider in ("fake", "rules"):
        return RuleBasedExtractor()
    raise RuntimeError(f"Unknown COOKBOOK_EXTRACTION_PROVIDER {provider!r}; only 'fake' exists so far.")


def run_extraction(extractor: Extractor, source_text: str, timeout_s: float) -> DraftContent:
    """Call the provider with a deadline, then validate its output against the source.

    On timeout the worker thread can't be killed; it finishes in the background and its
    result is discarded. Real providers should also set their own client timeout.
    """
    future = _pool.submit(extractor.extract, source_text)
    try:
        raw = future.result(timeout=timeout_s)
    except FutureTimeout:
        raise ExtractionTimeout() from None
    except (ExtractionError, MalformedOutput):
        raise
    except Exception as e:  # provider bug or SDK error: never leak details to clients
        raise ExtractionError(type(e).__name__) from e
    return validate_extraction(raw, source_text)


__all__ = [
    "ExtractionError",
    "ExtractionTimeout",
    "Extractor",
    "FakeExtractor",
    "MalformedOutput",
    "RuleBasedExtractor",
    "make_extractor",
    "run_extraction",
]
