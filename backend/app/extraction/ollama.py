"""Local-model provider: an Ollama server (default qwen2.5:7b) on this machine.

Captions never leave the Mac and there's no per-call cost. Ollama's structured-output
mode constrains generation to the ExtractionOutput JSON schema, but the output still goes
through validate.py like any other provider's, because a schema can't stop a model from
inventing an amount.
"""

import copy

import httpx

from app.extraction.base import ExtractionError, ExtractionOutput, ExtractionTimeout
from app.extraction.prompt import PROMPT_VERSION, SYSTEM_PROMPT

# Per-field caps added to the JSON schema sent to Ollama. Its grammar enforces maxLength, which
# stops the degenerate loops small models fall into (seen in eval: a "unit" that repeated
# "cups of sugar, cup of sugars, …" until the token limit).
_FIELD_CAPS = {"title": 200, "raw_text": 300, "name": 200, "unit": 20, "instruction": 1000}
# Upper bound on generated tokens; a runaway response fails fast as malformed output.
_MAX_OUTPUT_TOKENS = 2048


class OllamaExtractor:
    def __init__(
        self,
        base_url: str,
        model: str,
        timeout_s: float,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self.model = model
        self.version = f"ollama:{model}:{PROMPT_VERSION}"
        self._client = httpx.Client(base_url=base_url, timeout=timeout_s, transport=transport)
        self._schema = _ollama_schema(ExtractionOutput.model_json_schema())

    def extract(self, source_text: str) -> str:
        body = {
            "model": self.model,
            "stream": False,
            "format": self._schema,
            # Keep the model loaded between imports; cold loads take several seconds.
            "keep_alive": "15m",
            "options": {
                "temperature": 0,
                "num_ctx": 8192,
                "num_predict": _MAX_OUTPUT_TOKENS,
                "repeat_penalty": 1.1,
            },
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": f"<caption>\n{source_text}\n</caption>"},
            ],
        }
        try:
            res = self._client.post("/api/chat", json=body)
        except httpx.TimeoutException:
            raise ExtractionTimeout() from None
        except httpx.HTTPError as e:
            raise ExtractionError(f"ollama unreachable: {type(e).__name__}") from None
        if res.status_code != 200:
            # e.g. 404 when the model hasn't been pulled. Logged server-side, never returned.
            raise ExtractionError(f"ollama status {res.status_code}")
        try:
            return res.json()["message"]["content"]
        except (ValueError, KeyError, TypeError):
            raise ExtractionError("ollama response missing message content") from None


def _ollama_schema(schema: dict) -> dict:
    """Copy of a pydantic JSON schema prepared for Ollama's grammar-constrained output.

    - Every property is required (nullable ones may still be null). Ollama generates exactly
      what the schema allows, so optional keys get skipped: on a real caption Qwen omitted
      every ingredient `name`, tried to put "medium russet potatoes, cut into thin fries"
      in `unit`, and stopped after the first of three sections. Requiring `name`, which
      comes before `unit`, gives the description a place to go.
    - maxLength on the string fields in _FIELD_CAPS.
    """

    def walk(node):
        if isinstance(node, dict):
            if node.get("type") == "object" and "properties" in node:
                node["required"] = list(node["properties"])
            for name, prop in node.get("properties", {}).items():
                if name in _FIELD_CAPS:
                    for variant in prop.get("anyOf", [prop]):
                        if variant.get("type") == "string":
                            variant["maxLength"] = _FIELD_CAPS[name]
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
        return node

    return walk(copy.deepcopy(schema))
