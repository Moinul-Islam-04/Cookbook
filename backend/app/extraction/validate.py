"""Turn a provider's raw output into a reviewable draft, enforcing source fidelity.

The provider is untrusted: its output may be malformed, padded with prose, or invent
amounts the caption never stated. Nothing here is dropped silently. Anything not backed
by the caption is either removed (quantities, units) or flagged `needs_review`, and every
adjustment is visible to the user as a warning or a flagged row.
"""

import json
import re
from decimal import Decimal

from pydantic import ValidationError

from app.extraction.base import ExtractionOutput
from app.extraction.quantities import amounts_in, expand_unicode_fractions, parse_amount
from app.schemas import (
    MAX_INGREDIENTS,
    MAX_STEPS,
    DraftContent,
    DraftWarning,
    IngredientDraft,
    StepDraft,
)

MAX_QUANTITY = Decimal("9999999.999")  # NUMERIC(10, 3)


class MalformedOutput(Exception):
    """The provider returned something that isn't the agreed JSON shape."""


def _norm(text: str) -> str:
    text = expand_unicode_fractions(text).lower()
    text = re.sub(r"[‘’]", "'", text)
    text = re.sub(r"[“”]", '"', text)
    return re.sub(r"\s+", " ", text).strip()


def _in_source(fragment: str, source_norm: str) -> bool:
    frag = _norm(fragment).strip(" .,;:!-•*")
    return bool(frag) and frag in source_norm


def _clip(text: str | None, limit: int) -> tuple[str | None, bool]:
    if text is None:
        return None, False
    text = text.strip()
    if not text:
        return None, False
    return (text[:limit], True) if len(text) > limit else (text, False)


def _parse_json(raw: str) -> ExtractionOutput:
    text = raw.strip()
    # Models often wrap JSON in a ```json fence; accept that, nothing looser.
    fence = re.fullmatch(r"```(?:json)?\s*(.*?)\s*```", text, flags=re.S)
    if fence:
        text = fence.group(1)
    try:
        return ExtractionOutput.model_validate(json.loads(text))
    except (json.JSONDecodeError, ValidationError, TypeError) as e:
        raise MalformedOutput(type(e).__name__) from None


def validate_extraction(raw: str, source_text: str) -> DraftContent:
    out = _parse_json(raw)
    source = _norm(source_text)
    warnings: list[DraftWarning] = []

    if not out.is_recipe or (not out.ingredients and not out.steps):
        return DraftContent(
            title=None,
            ingredients=[],
            steps=[],
            warnings=[
                DraftWarning(
                    code="no_recipe_found",
                    message="No usable recipe found in this text. You can enter it manually instead.",
                )
            ],
        )

    # Title: only one the caption actually states; otherwise ask the user to name it.
    title, _ = _clip(out.title, 200)
    if title is not None and not _in_source(title, source):
        title = None
    if title is None:
        warnings.append(DraftWarning(code="title_missing", message="Give this recipe a title.", field="title"))

    ingredients: list[IngredientDraft] = []
    raw_ingredients = out.ingredients
    if len(raw_ingredients) > MAX_INGREDIENTS:
        raw_ingredients = raw_ingredients[:MAX_INGREDIENTS]
        warnings.append(DraftWarning(code="too_many_items", message=f"Only the first {MAX_INGREDIENTS} ingredients were kept."))
    for item in raw_ingredients:
        raw_text, clipped = _clip(item.raw_text, 500)
        if raw_text is None:
            continue  # nothing the user could review
        reasons: list[str] = ["too_long"] if clipped else []
        if not _in_source(raw_text, source):
            reasons.append("not_in_source")

        name, name_clipped = _clip(item.name, 200)
        if name_clipped:
            reasons.append("too_long")
        if name is None:
            reasons.append("name_missing")
        elif _norm(name) not in _norm(raw_text):
            reasons.append("name_not_in_source")

        # A quantity is kept only if that amount is written in this ingredient's own text.
        quantity = parse_amount(str(item.quantity)) if item.quantity is not None else None
        if item.quantity is not None and (
            quantity is None or quantity > MAX_QUANTITY or quantity not in amounts_in(raw_text)
        ):
            quantity = None
            reasons.append("quantity_not_in_source")

        unit, _ = _clip(item.unit, 40)
        if unit is not None and not re.search(rf"(?<!\w){re.escape(unit.lower())}(?!\w)", _norm(raw_text)):
            unit = None
            reasons.append("unit_not_in_source")

        ingredients.append(
            IngredientDraft(
                name=name,
                quantity=quantity,
                unit=unit,
                raw_text=raw_text,
                needs_review=bool(reasons),
                review_reasons=sorted(set(reasons)),
            )
        )

    steps: list[StepDraft] = []
    raw_steps = out.steps
    if len(raw_steps) > MAX_STEPS:
        raw_steps = raw_steps[:MAX_STEPS]
        warnings.append(DraftWarning(code="too_many_items", message=f"Only the first {MAX_STEPS} steps were kept."))
    for item in raw_steps:
        instruction, clipped = _clip(item.instruction, 2000)
        if instruction is None:
            continue
        reasons = ["too_long"] if clipped else []
        if not _in_source(instruction, source):
            reasons.append("not_in_source")
        steps.append(StepDraft(instruction=instruction, needs_review=bool(reasons), review_reasons=reasons))

    if not ingredients:
        warnings.append(DraftWarning(code="missing_ingredients", message="No ingredients were found. Add them before saving.", field="ingredients"))
    if not steps:
        warnings.append(DraftWarning(code="missing_steps", message="No steps were found. Add them before saving.", field="steps"))
    flagged = sum(i.needs_review for i in ingredients) + sum(s.needs_review for s in steps)
    if flagged:
        warnings.append(
            DraftWarning(
                code="needs_review",
                message=f"{flagged} item(s) didn't match the caption exactly. Check them before saving.",
            )
        )

    return DraftContent(title=title, ingredients=ingredients, steps=steps, warnings=warnings)
