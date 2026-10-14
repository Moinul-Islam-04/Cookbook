"""The extraction contract every provider (fake, local model, hosted model) implements.

A provider turns caption text into a JSON string shaped like `ExtractionOutput`. It
returns the *raw* string, so the same validator (validate.py) handles every provider's
malformed or unfaithful output. Providers never see the database or the user.
"""

from typing import Protocol

from pydantic import BaseModel, ConfigDict


class ExtractionError(Exception):
    """The provider failed or is unreachable (maps to 502/503, retryable)."""


class ExtractionTimeout(Exception):
    """The provider didn't answer within the configured bound (maps to 504)."""


class Extractor(Protocol):
    # Stored on every draft so output can be traced to the provider and prompt version.
    version: str

    def extract(self, source_text: str) -> str: ...


# ---- the JSON shape providers are asked to return (and LLMs will be prompted with) ----


class RawIngredient(BaseModel):
    model_config = ConfigDict(extra="ignore")

    raw_text: str
    name: str | None = None
    quantity: float | str | None = None
    unit: str | None = None


class RawStep(BaseModel):
    model_config = ConfigDict(extra="ignore")

    instruction: str


class ExtractionOutput(BaseModel):
    model_config = ConfigDict(extra="ignore")

    is_recipe: bool
    title: str | None = None
    ingredients: list[RawIngredient] = []
    steps: list[RawStep] = []
