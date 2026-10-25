"""The extraction contract every provider (fake, local model, hosted model) implements.

A provider turns a post (app/ingest RawPost: caption, optional transcript and comments)
into a JSON string shaped like `ExtractionOutput`, the spec's ParsedRecipe. It returns
the *raw* string, so the same validator (validate.py) handles every provider's malformed
or unfaithful output. Providers never see the database or the user.
"""

from typing import TYPE_CHECKING, Literal, Protocol

from pydantic import BaseModel, ConfigDict, Field

if TYPE_CHECKING:
    from app.ingest import RawPost


class ExtractionError(Exception):
    """The provider failed or is unreachable (maps to 502/503, retryable)."""


class ProviderUnreachable(ExtractionError):
    """A hosted provider couldn't be reached, e.g. the server has no internet (503, retryable)."""


class ProviderAccountProblem(ExtractionError):
    """The hosted provider rejected our account: out of credit or a bad key (503, not retryable)."""


class ExtractionTimeout(Exception):
    """The provider didn't answer within the configured bound (maps to 504)."""


class Extractor(Protocol):
    # Stored on every draft so output can be traced to the provider and prompt version.
    version: str

    def extract(self, post: "RawPost | str") -> str: ...


# ---- the JSON shape providers are asked to return (and LLMs will be prompted with) ----


class RawIngredient(BaseModel):
    model_config = ConfigDict(extra="ignore")

    raw_text: str
    name: str | None = None
    quantity: float | str | None = None
    unit: str | None = None
    # Preparation or descriptor from raw_text: "heaping", "finely chopped".
    note: str | None = None


class RawStep(BaseModel):
    model_config = ConfigDict(extra="ignore")

    instruction: str


SourceField = Literal["caption", "transcript", "comments"]


class SubRecipeOutput(BaseModel):
    """A part made separately (a sauce, a marinade). One level deep: structured outputs
    need a finite schema, and no eval case has needed more."""

    model_config = ConfigDict(extra="ignore")

    title: str | None = None
    ingredients: list[RawIngredient] = []
    steps: list[RawStep] = []


class ExtractionOutput(BaseModel):
    model_config = ConfigDict(extra="ignore")

    is_recipe: bool
    title: str | None = None
    servings: int | None = None
    ingredients: list[RawIngredient] = []
    steps: list[RawStep] = []
    sub_recipes: list[SubRecipeOutput] = []
    source_fields_used: list[SourceField] = []
    # The model's own 0-1 estimate; validate.py clamps it and never trusts it for fidelity.
    confidence: float | None = Field(default=None)
