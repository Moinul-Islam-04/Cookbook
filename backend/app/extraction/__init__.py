"""Caption → draft extraction behind a provider-neutral adapter."""

from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from typing import TYPE_CHECKING

from app.extraction.base import ExtractionError, ExtractionTimeout, Extractor
from app.extraction.fake import FakeExtractor, RuleBasedExtractor
from app.extraction.validate import MalformedOutput, validate_extraction
from app.schemas import DraftContent

if TYPE_CHECKING:
    from app.config import Settings

# Bounded pool: a stalled provider can occupy at most this many threads.
_pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="extract")


def make_extractor(settings: "Settings") -> Extractor:
    provider = settings.extraction_provider
    if provider in ("fake", "rules"):
        return RuleBasedExtractor()
    if provider == "ollama":
        from app.extraction.ollama import OllamaExtractor

        return OllamaExtractor(settings.ollama_url, settings.ollama_model, settings.extraction_timeout_s)
    if provider == "anthropic":
        if not settings.anthropic_api_key:
            raise RuntimeError("COOKBOOK_EXTRACTION_PROVIDER=anthropic needs COOKBOOK_ANTHROPIC_API_KEY.")
        from app.extraction.anthropic import AnthropicExtractor

        return AnthropicExtractor(
            settings.anthropic_api_key, settings.anthropic_model, settings.extraction_timeout_s
        )
    raise RuntimeError(
        f"Unknown COOKBOOK_EXTRACTION_PROVIDER {provider!r}; use 'fake', 'ollama' or 'anthropic'."
    )


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
    except (ExtractionError, ExtractionTimeout, MalformedOutput):
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
