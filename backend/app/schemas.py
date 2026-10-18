"""API request/response contracts.

Requests use extra="forbid", so a client cannot smuggle in fields such as user_id;
ownership always comes from the server-side identity.
"""

import uuid
from datetime import datetime
from decimal import Decimal
from typing import Annotated, Any

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    PlainSerializer,
    StringConstraints,
    field_validator,
    model_validator,
)

MAX_INGREDIENTS = 200
MAX_STEPS = 200

Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]
IngredientName = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)
]
Unit = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]
RawText = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=500)]
Notes = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=5000)]
SourceUrl = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2048)]
Instruction = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=2000)
]
# NUMERIC(10, 3) in PostgreSQL. Sent to clients as a JSON number.
Quantity = Annotated[
    Decimal,
    Field(gt=0, max_digits=10, decimal_places=3),
    PlainSerializer(float, return_type=float, when_used="json"),
]


def _blank_to_none(value: Any) -> Any:
    if isinstance(value, str) and not value.strip():
        return None
    return value


class RequestModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class IngredientIn(RequestModel):
    name: IngredientName
    quantity: Quantity | None = None
    unit: Unit | None = None
    # What the user (or later, the source caption) actually wrote, e.g. "salt to taste".
    # If omitted, the server composes it from quantity/unit/name.
    raw_text: RawText | None = None

    _blank_optional = field_validator("unit", "raw_text", mode="before")(_blank_to_none)


class StepIn(RequestModel):
    instruction: Instruction


class RecipeCreate(RequestModel):
    # Set when saving a reviewed import draft: the recipe records the caption as its
    # source, and the draft is marked saved in the same transaction.
    draft_id: uuid.UUID | None = None
    title: Title
    notes: Notes | None = None
    # An Instagram post or reel link. Normalized by the server; other hosts are rejected.
    source_url: SourceUrl | None = None
    # Save even if this post is already in the cookbook (the user chose "Save Anyway").
    allow_duplicate: bool = False
    # Empty lists are allowed: incomplete recipes are saved and flagged via `missing`.
    ingredients: list[IngredientIn] = Field(default_factory=list, max_length=MAX_INGREDIENTS)
    steps: list[StepIn] = Field(default_factory=list, max_length=MAX_STEPS)

    _blank_optional = field_validator("notes", "source_url", mode="before")(_blank_to_none)


class RecipePatch(RequestModel):
    """Omitted fields stay unchanged. Supplied ingredient/step arrays replace all rows."""

    version: int = Field(ge=1)
    title: Title | None = None
    notes: Notes | None = None
    # null clears the link.
    source_url: SourceUrl | None = None
    allow_duplicate: bool = False
    ingredients: list[IngredientIn] | None = Field(default=None, max_length=MAX_INGREDIENTS)
    steps: list[StepIn] | None = Field(default=None, max_length=MAX_STEPS)

    _blank_optional = field_validator("notes", "source_url", mode="before")(_blank_to_none)

    @model_validator(mode="after")
    def _reject_explicit_nulls(self) -> "RecipePatch":
        for field in ("title", "ingredients", "steps"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null; omit it to leave it unchanged")
        return self


class IngredientOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    position: int
    name: str
    quantity: Quantity | None
    unit: str | None
    raw_text: str


class StepOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    position: int
    instruction: str


class RecipeImageOut(BaseModel):
    id: uuid.UUID
    position: int
    width: int
    height: int
    # Relative, signed, short-lived: resolve against the API base URL. No auth header needed.
    url: str
    thumbnail_url: str
    urls_expire_at: datetime


class RecipeOut(BaseModel):
    id: uuid.UUID
    title: str
    notes: str | None
    source_kind: str
    source_url: str | None
    created_at: datetime
    updated_at: datetime
    version: int
    ingredients: list[IngredientOut]
    steps: list[StepOut]
    images: list[RecipeImageOut] = []
    missing: list[str]


class RecipeSummary(BaseModel):
    id: uuid.UUID
    title: str
    source_url: str | None
    ingredient_count: int
    step_count: int
    missing: list[str]
    # The first photo's thumbnail (signed, short-lived), if any.
    thumbnail_url: str | None = None
    created_at: datetime
    updated_at: datetime


class RecipePage(BaseModel):
    items: list[RecipeSummary]
    next_cursor: str | None


class FieldError(BaseModel):
    field: str
    message: str


class ErrorBody(BaseModel):
    code: str
    message: str
    field_errors: list[FieldError] = []
    retryable: bool = False
    request_id: str | None = None
    details: dict[str, Any] | None = None


# ---------- import drafts (Milestone 3) ----------

MAX_SOURCE_TEXT = 10_000
SourceText = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=MAX_SOURCE_TEXT)
]


class DraftWarning(BaseModel):
    code: str
    message: str
    field: str | None = None
    # duplicate_post: the recipe that already has this post.
    recipe_id: uuid.UUID | None = None


class IngredientDraft(BaseModel):
    """Like IngredientIn, but name may be missing and a row can be flagged for review."""

    name: str | None = None
    quantity: Quantity | None = None
    unit: str | None = None
    raw_text: str
    needs_review: bool = False
    # e.g. "not_in_source", "quantity_not_in_source", "name_missing"
    review_reasons: list[str] = []


class StepDraft(BaseModel):
    instruction: str
    needs_review: bool = False
    review_reasons: list[str] = []


class DraftContent(BaseModel):
    title: str | None
    ingredients: list[IngredientDraft]
    steps: list[StepDraft]
    warnings: list[DraftWarning]


class ImportDraftCreate(RequestModel):
    # The caption the user pasted. Treated as data only: it never changes extraction rules.
    source_text: SourceText
    source_url: SourceUrl | None = None

    _blank_optional = field_validator("source_url", mode="before")(_blank_to_none)


class IngredientDraftIn(RequestModel):
    name: IngredientName | None = None
    quantity: Quantity | None = None
    unit: Unit | None = None
    raw_text: RawText
    needs_review: bool = False

    _blank_optional = field_validator("name", "unit", mode="before")(_blank_to_none)


class StepDraftIn(RequestModel):
    instruction: Instruction
    needs_review: bool = False


class ImportDraftPatch(RequestModel):
    """Persist the user's corrections so they survive a failed save or an app restart."""

    version: int = Field(ge=1)
    title: Title | None = None
    ingredients: list[IngredientDraftIn] | None = Field(default=None, max_length=MAX_INGREDIENTS)
    steps: list[StepDraftIn] | None = Field(default=None, max_length=MAX_STEPS)

    @model_validator(mode="after")
    def _reject_explicit_nulls(self) -> "ImportDraftPatch":
        for field in ("ingredients", "steps"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be null; omit it to leave it unchanged")
        return self


class ImportDraftOut(BaseModel):
    id: uuid.UUID
    status: str  # "ready" | "saved"
    source_text: str
    source_url: str | None
    title: str | None
    ingredients: list[IngredientDraft]
    steps: list[StepDraft]
    warnings: list[DraftWarning]
    extraction_version: str
    version: int
    saved_recipe_id: uuid.UUID | None
    created_at: datetime
    updated_at: datetime
    expires_at: datetime


class GoogleSignIn(RequestModel):
    # A Google ID token is a JWT of roughly 1–2 KB.
    id_token: str = Field(min_length=1, max_length=8192)
    device_name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]


class SessionOut(BaseModel):
    """A device token, shown once. Send it as `Authorization: Bearer <token>`."""

    token: str
    token_id: uuid.UUID
    expires_at: datetime
