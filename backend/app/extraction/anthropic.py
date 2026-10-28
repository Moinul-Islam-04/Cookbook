"""Hosted-model provider: Claude (default Haiku 5.5) through the Anthropic API.

The post (caption, and any transcript and comments) is sent to Anthropic and each call costs money (about
$0.10 per million input tokens and $0.50 per million output tokens). Structured outputs
constrain the reply to the ExtractionOutput JSON schema; the output still goes through
validate.py like any other provider's.
"""

import copy
import time

import anthropic

from app.extraction.base import (
    ExtractionError,
    ExtractionOutput,
    ExtractionTimeout,
    ProviderAccountProblem,
    ProviderUnreachable,
)
from app.extraction.prompt import PROMPT_VERSION, SYSTEM_PROMPT
from app.extraction.source import as_post, render_post
from app.ingest import RawPost

# Room for adaptive thinking plus the JSON; a long reel's JSON is about 1,500 tokens.
_MAX_OUTPUT_TOKENS = 8000

# Time budget (DECISIONS 2026-10-20, 2026-10-28). Haiku takes a few seconds for most posts,
# but a long recipe (21 ingredients, 15 steps; about 4,400 output tokens) took 15-16 s.
# The SDK's own retry is off: it sleeps for any Retry-After the API sends, with no cap, so one retry could outlive run_extraction's deadline. Instead extract()
# makes at most two attempts, both inside `timeout_s` minus a margin.
_ATTEMPT_READ_S = 35.0  # one call's wait for the reply: about 2x the slowest recipe seen
_CONNECT_S = 3.0
_MIN_RETRY_READ_S = 15.0  # retry only with time for a typical post's reply
_RETRY_DELAY_S = 0.5  # the SDK's first backoff, when the API doesn't send Retry-After
_DEADLINE_MARGIN_S = 1.0  # fail here before run_extraction gives up, so the error is precise


class AnthropicExtractor:
    def __init__(
        self,
        api_key: str,
        model: str,
        timeout_s: float,
        http_client: anthropic.DefaultHttpxClient | None = None,
    ) -> None:
        self.model = model
        self.version = f"anthropic:{model}:{PROMPT_VERSION}"
        self._budget_s = timeout_s - _DEADLINE_MARGIN_S
        self._client = anthropic.Anthropic(api_key=api_key, max_retries=0, http_client=http_client)
        self._schema = _strict_schema(ExtractionOutput.model_json_schema())
        # (input_tokens, output_tokens) of the last call, for the eval's cost column.
        self.last_usage: tuple[int, int] | None = None

    def extract(self, post: RawPost | str) -> str:
        user_content = render_post(as_post(post))
        deadline = time.monotonic() + self._budget_s
        retried = False
        while True:
            read_s = min(_ATTEMPT_READ_S, deadline - time.monotonic() - _CONNECT_S)
            try:
                msg = self._call(user_content, read_s)
                break
            except anthropic.APIError as e:
                delay = _retry_delay(e)
                if (
                    retried
                    or delay is None
                    or deadline - time.monotonic() - delay - _CONNECT_S < _MIN_RETRY_READ_S
                ):
                    raise _extraction_error(e) from None
                time.sleep(delay)
                retried = True
        self.last_usage = (msg.usage.input_tokens, msg.usage.output_tokens)
        if msg.stop_reason == "refusal":
            raise ExtractionError("anthropic refused")
        text = next((b.text for b in msg.content if b.type == "text"), None)
        if text is None:
            raise ExtractionError(f"anthropic returned no text (stop_reason={msg.stop_reason})")
        # A max_tokens cut leaves truncated JSON, which the validator rejects as malformed.
        return text

    def _call(self, user_content: str, read_s: float):
        return self._client.messages.create(
            model=self.model,
            max_tokens=_MAX_OUTPUT_TOKENS,
            system=SYSTEM_PROMPT,
            # At "low", Haiku sometimes split a paragraph's sentences into clauses (eval, prompt-6).
            output_config={"effort": "medium", "format": {"type": "json_schema", "schema": self._schema}},
            messages=[{"role": "user", "content": user_content}],
            timeout=anthropic.Timeout(max(read_s, 0.1), connect=_CONNECT_S),
        )


def _retry_delay(e: anthropic.APIError) -> float | None:
    """Seconds to wait before retrying `e`, or None if retrying won't help. Same errors as
    the SDK retries: timeouts, lost connections, 408, 409, 429 and 5xx (including 529)."""
    if isinstance(e, anthropic.APIConnectionError):  # includes APITimeoutError
        return _RETRY_DELAY_S
    if isinstance(e, anthropic.APIStatusError) and (e.status_code in (408, 409, 429) or e.status_code >= 500):
        headers = e.response.headers
        for name, scale in (("retry-after-ms", 0.001), ("retry-after", 1.0)):
            try:
                return max(0.0, float(headers[name]) * scale)
            except (KeyError, TypeError, ValueError):
                pass
        return _RETRY_DELAY_S
    return None


def _extraction_error(e: anthropic.APIError) -> Exception:
    """The provider-neutral error for `e`. The provider's message stays out of it: the body
    may echo request details."""
    if isinstance(e, anthropic.APITimeoutError):
        return ExtractionTimeout()
    if isinstance(e, anthropic.APIConnectionError):
        return ProviderUnreachable(f"anthropic unreachable: {type(e).__name__}")
    if isinstance(e, anthropic.APIStatusError):
        # 401 bad key, 402 billing (out of credit), 403 key not allowed: retrying won't help.
        if e.status_code in (401, 402, 403):
            return ProviderAccountProblem(f"anthropic status {e.status_code}")
        return ExtractionError(f"anthropic status {e.status_code}")
    return ExtractionError(type(e).__name__)


def _strict_schema(schema: dict) -> dict:
    """Copy of a pydantic JSON schema in the form structured outputs accept.

    Every object gets additionalProperties: false and every property is required (nullable
    ones may still be null). Pydantic's "title" and "default" annotations are
    dropped; property names are left alone.
    """

    def walk(node):
        if isinstance(node, dict):
            node.pop("default", None)
            if isinstance(node.get("title"), str):
                del node["title"]
            if node.get("type") == "object" and "properties" in node:
                node["required"] = list(node["properties"])
                node["additionalProperties"] = False
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
        return node

    return walk(copy.deepcopy(schema))
