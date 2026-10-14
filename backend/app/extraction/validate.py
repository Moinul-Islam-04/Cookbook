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

from app.extraction.base import ExtractionOutput, RawIngredient
from app.extraction.quantities import (
    amounts_in,
    expand_unicode_fractions,
    parse_amount,
    split_ingredient_line,
)
from app.schemas import (
    MAX_INGREDIENTS,
    MAX_STEPS,
    DraftContent,
    DraftWarning,
    IngredientDraft,
    StepDraft,
)

MAX_QUANTITY = Decimal("9999999.999")  # NUMERIC(10, 3)
# A model may write 1/3 as 0.33; accept that as the caption's amount, and store the exact one.
QUANTITY_TOLERANCE = Decimal("0.01")


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


def _source_amount(claimed: Decimal, raw_text: str) -> Decimal | None:
    """The amount written in raw_text that the model's number refers to, if any."""
    for amount in amounts_in(raw_text):
        if abs(amount - claimed) <= QUANTITY_TOLERANCE:
            return amount
    return None


def _unit_in(unit: str, raw_text: str) -> bool:
    """Whole-word match, but allow "500g" (digit before) and cup/cups (plural)."""
    stem = re.escape(unit.lower().rstrip("s"))
    return bool(re.search(rf"(?<![a-z]){stem}(?:e?s)?(?![a-z])", _norm(raw_text)))


def _split_comma_lists(items: list[RawIngredient]) -> list[RawIngredient]:
    """Split "3 bananas, 1 egg, 1 cup flour" (one entry from a model) into three.

    Only when every comma-separated piece starts with an amount, so "3 cloves garlic,
    minced" stays whole. Pieces are caption text, so nothing is invented; the model's
    quantity/unit/name for the merged line are dropped and re-read per piece.
    """
    result = []
    for item in items:
        pieces = [p.strip() for p in item.raw_text.split(",")]
        if len(pieces) > 1 and all(p and split_ingredient_line(p)[0] is not None for p in pieces):
            result += [RawIngredient(raw_text=p) for p in pieces]
        else:
            result.append(item)
    return result


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

    # "Not a recipe" plus a stray sentence in steps is chatter (seen in eval); "not a
    # recipe" with ingredients is kept for review with a warning, so nothing real is lost.
    if not out.ingredients and (not out.steps or not out.is_recipe):
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

    if not out.is_recipe:
        warnings.append(
            DraftWarning(code="uncertain_recipe", message="This might not be a recipe. Check everything carefully.")
        )

    ingredients: list[IngredientDraft] = []
    raw_ingredients = _split_comma_lists(out.ingredients)
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

        # What the line itself says, read deterministically. Used only to fill fields the
        # model left empty: it comes from the caption, so it can't be invented.
        line_qty, line_unit, line_name = split_ingredient_line(raw_text)

        name, name_clipped = _clip(item.name, 200)
        if name_clipped:
            reasons.append("too_long")
        if name is None:
            name, _ = _clip(line_name, 200)
        if name is None:
            reasons.append("name_missing")
        elif _norm(name) not in _norm(raw_text):
            reasons.append("name_not_in_source")

        # A quantity is kept only if that amount is written in this ingredient's own text.
        if item.quantity is not None:
            claimed = parse_amount(str(item.quantity))
            quantity = _source_amount(claimed, raw_text) if claimed is not None else None
            if quantity is None or quantity > MAX_QUANTITY:
                quantity = None
                reasons.append("quantity_not_in_source")
        else:
            quantity = line_qty

        unit, _ = _clip(item.unit, 40)
        if unit is not None and not _unit_in(unit, raw_text):
            unit = None
            reasons.append("unit_not_in_source")
        elif unit is None and item.quantity is None:
            unit = line_unit

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
