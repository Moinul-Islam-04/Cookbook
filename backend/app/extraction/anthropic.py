"""Hosted-model provider: Claude (default Haiku 5.5) through the Anthropic API.

Unlike the Ollama provider, the caption leaves the Mac and each call costs money (about
$0.10 per million input tokens and $0.50 per million output tokens). Structured outputs
constrain the reply to the ExtractionOutput JSON schema; the output still goes through
validate.py like any other provider's.
"""

import copy

import anthropic

from app.extraction.base import (
    ExtractionError,
    ExtractionOutput,
    ExtractionTimeout,
    ProviderAccountProblem,
    ProviderUnreachable,
)
from app.extraction.prompt import PROMPT_VERSION, SYSTEM_PROMPT

# Room for adaptive thinking plus the JSON; a long reel's JSON is about 1,500 tokens.
_MAX_OUTPUT_TOKENS = 8000


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
        # One SDK retry for 429/5xx; run_extraction's deadline still bounds the total.
        self._client = anthropic.Anthropic(
            api_key=api_key, timeout=timeout_s, max_retries=1, http_client=http_client
        )
        self._schema = _strict_schema(ExtractionOutput.model_json_schema())
        # (input_tokens, output_tokens) of the last call, for the eval's cost column.
        self.last_usage: tuple[int, int] | None = None

    def extract(self, source_text: str) -> str:
        try:
            msg = self._client.messages.create(
                model=self.model,
                max_tokens=_MAX_OUTPUT_TOKENS,
                system=SYSTEM_PROMPT,
                # Copying text out of a caption needs little reasoning; low effort keeps it fast.
                output_config={"effort": "low", "format": {"type": "json_schema", "schema": self._schema}},
                messages=[{"role": "user", "content": f"<caption>\n{source_text}\n</caption>"}],
            )
        except anthropic.APITimeoutError:
            raise ExtractionTimeout() from None
        except anthropic.APIStatusError as e:
            # Logged server-side, never returned; the body may echo request details.
            # 401 bad key, 402 billing (out of credit), 403 key not allowed: retrying won't help.
            if e.status_code in (401, 402, 403):
                raise ProviderAccountProblem(f"anthropic status {e.status_code}") from None
            raise ExtractionError(f"anthropic status {e.status_code}") from None
        except anthropic.APIConnectionError as e:
            raise ProviderUnreachable(f"anthropic unreachable: {type(e).__name__}") from None
        self.last_usage = (msg.usage.input_tokens, msg.usage.output_tokens)
        if msg.stop_reason == "refusal":
            raise ExtractionError("anthropic refused")
        text = next((b.text for b in msg.content if b.type == "text"), None)
        if text is None:
            raise ExtractionError(f"anthropic returned no text (stop_reason={msg.stop_reason})")
        # A max_tokens cut leaves truncated JSON, which the validator rejects as malformed.
        return text


def _strict_schema(schema: dict) -> dict:
    """Copy of a pydantic JSON schema in the form structured outputs accept.

    Every object gets additionalProperties: false and every property is required (nullable
    ones may still be null), as for Ollama. Pydantic's "title" and "default" annotations are
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
