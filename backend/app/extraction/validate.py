"""Turn a provider's raw output into a reviewable draft, enforcing source fidelity.

The provider is untrusted: its output may be malformed, padded with prose, or invent
amounts the post never stated. "The post" is everything the model was given: caption,
transcript and comments. Nothing a user would see is dropped silently. Anything not backed
by the post is either removed (quantities, units, notes) or flagged `needs_review`, and
every adjustment is visible to the user as a warning or a flagged row.

Sanity checks beyond fidelity: amounts must be positive, units are mapped to one spelling
from a known list (others are kept but flagged), servings are kept only when the post
states them, and the model's confidence is clamped to 0-1.
"""

import json
import re
from decimal import Decimal

from pydantic import ValidationError

from app.extraction.base import ExtractionOutput, RawIngredient, RawStep
from app.extraction.quantities import (
    amounts_in,
    canonical_unit,
    expand_unicode_fractions,
    parse_amount,
    spell_numbers,
    split_ingredient_line,
)
from app.extraction.source import as_post, fidelity_text, supplied_fields
from app.ingest import RawPost
from app.schemas import (
    MAX_INGREDIENTS,
    MAX_STEPS,
    DraftContent,
    DraftWarning,
    IngredientDraft,
    StepDraft,
    SubRecipeDraft,
)

MAX_QUANTITY = Decimal("9999999.999")  # NUMERIC(10, 3)
# A model may write 1/3 as 0.33; accept that as the caption's amount, and store the exact one.
QUANTITY_TOLERANCE = Decimal("0.01")
MAX_SERVINGS = 1000
# Below this self-reported confidence the user is told to check everything.
LOW_CONFIDENCE = 0.5
# The post itself says where the recipe is ("link in bio", "on my blog", "in the comments").
_POINTS_ELSEWHERE = re.compile(r"\b(?:bio|blog|website|link|linked|substack|comments?|newsletter)\b")


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


def _servings_in(servings: int | None, source_norm: str) -> int | None:
    """The servings count, only if the post states it ("serves 4", "makes 12", "4 servings")."""
    if servings is None or not 1 <= servings <= MAX_SERVINGS:
        return None
    text = spell_numbers(source_norm)
    n = rf"(?<![\d/.]){servings}(?![\d]|[/.]\d)"  # "4." ends a sentence; "4.5" and "4/5" aren't 4
    if re.search(rf"\b(?:serves|servings?|makes|yields?|feeds|portions?)\b\W{{0,3}}(?:about |up to )?{n}", text) or re.search(
        rf"{n}\s*(?:servings|portions|people|serves)\b", text
    ):
        return servings
    return None


def _ingredient(item: RawIngredient, source: str, sub_recipe: int | None) -> IngredientDraft | None:
    raw_text, clipped = _clip(item.raw_text, 500)
    if raw_text is None:
        return None  # nothing the user could review
    reasons: list[str] = ["too_long"] if clipped else []
    if not _in_source(raw_text, source):
        reasons.append("not_in_source")

    # What the line itself says, read deterministically. Used only to fill fields the
    # model left empty: it comes from the post, so it can't be invented.
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

    # A quantity is kept only if that amount is written (or spoken) in this ingredient's
    # own text. parse_amount rejects zero and negative amounts.
    if item.quantity is not None:
        claimed = parse_amount(str(item.quantity))
        quantity = _source_amount(claimed, raw_text) if claimed is not None else None
        if quantity is None or quantity > MAX_QUANTITY:
            quantity = None
            reasons.append("quantity_not_in_source")
    else:
        quantity = line_qty

    # When the model's unit is missing or not in the line (Qwen writes "cup(s)"), use
    # the line's own unit, but only if the amount we kept is the line's leading amount
    # ("½ cup soy sauce" -> "cup"). Otherwise drop it and flag the row.
    unit, _ = _clip(item.unit, 40)
    line_unit_applies = line_unit is not None and (item.quantity is None or quantity == line_qty)
    if unit is not None and not _unit_in(unit, raw_text):
        if line_unit_applies:
            unit = line_unit
        else:
            unit = None
            reasons.append("unit_not_in_source")
    elif unit is None and line_unit_applies:
        unit = line_unit
    if unit is not None:
        canonical = canonical_unit(unit)
        if canonical is None:
            reasons.append("unit_unknown")
        else:
            unit = canonical

    # A note is a descriptor copied from the line ("heaping"); anything else is dropped.
    note, _ = _clip(item.note, 200)
    if note is not None and _norm(note).strip(" ,.") not in _norm(raw_text):
        note = None
        reasons.append("note_not_in_source")

    return IngredientDraft(
        name=name,
        quantity=quantity,
        unit=unit,
        raw_text=raw_text,
        note=note,
        sub_recipe=sub_recipe,
        needs_review=bool(reasons),
        review_reasons=sorted(set(reasons)),
    )


def _step(item: RawStep, source: str, sub_recipe: int | None) -> StepDraft | None:
    instruction, clipped = _clip(item.instruction, 2000)
    if instruction is None:
        return None
    reasons = ["too_long"] if clipped else []
    if not _in_source(instruction, source):
        reasons.append("not_in_source")
    return StepDraft(instruction=instruction, sub_recipe=sub_recipe, needs_review=bool(reasons), review_reasons=reasons)


def validate_extraction(raw: str, post: RawPost | str) -> DraftContent:
    out = _parse_json(raw)
    post = as_post(post)
    source = _norm(fidelity_text(post))
    warnings: list[DraftWarning] = []

    confidence = None if out.confidence is None else min(max(out.confidence, 0.0), 1.0)
    supplied = supplied_fields(post)
    meta = dict(
        is_recipe=out.is_recipe,
        confidence=confidence,
        source_fields_used=[f for f in dict.fromkeys(out.source_fields_used) if f in supplied],
    )

    # Sub-recipes keep their rows only if they have any; their index is their position here.
    parts: list[tuple[int | None, list[RawIngredient], list[RawStep]]] = [(None, out.ingredients, out.steps)]
    sub_recipes: list[SubRecipeDraft] = []
    for sub in out.sub_recipes:
        if not sub.ingredients and not sub.steps:
            continue
        title, _ = _clip(sub.title, 200)
        sub_recipes.append(SubRecipeDraft(title=title if title is not None and _in_source(title, source) else None))
        parts.append((len(sub_recipes) - 1, sub.ingredients, sub.steps))
    any_ingredients = any(ingredients for _, ingredients, _ in parts)
    any_steps = any(steps for _, _, steps in parts)

    # "Not a recipe" plus a stray sentence in steps is chatter (seen in eval); "not a
    # recipe" with ingredients is kept for review with a warning, so nothing real is lost.
    if not any_ingredients and (not any_steps or not out.is_recipe):
        warnings = [
            DraftWarning(
                code="no_recipe_found",
                message="No usable recipe found in this text. You can enter it manually instead.",
            )
        ]
        if out.is_recipe and _POINTS_ELSEWHERE.search(source):
            # "Recipe at the link in bio": the dish is real, its recipe isn't in the post.
            warnings.append(
                DraftWarning(
                    code="recipe_elsewhere",
                    message="This post points to a recipe somewhere else, like a link in bio. Paste it from there, or enter it manually.",
                )
            )
        return DraftContent(title=None, ingredients=[], steps=[], warnings=warnings, **meta)

    # Title: only one the post actually states; otherwise ask the user to name it.
    title, _ = _clip(out.title, 200)
    if title is not None and not _in_source(title, source):
        title = None
    if title is None:
        warnings.append(DraftWarning(code="title_missing", message="Give this recipe a title.", field="title"))

    if not out.is_recipe:
        warnings.append(
            DraftWarning(code="uncertain_recipe", message="This might not be a recipe. Check everything carefully.")
        )
    elif confidence is not None and confidence < LOW_CONFIDENCE:
        warnings.append(
            DraftWarning(code="low_confidence", message="The recipe reader wasn't sure about this one. Check everything carefully.")
        )

    ingredients: list[IngredientDraft] = []
    steps: list[StepDraft] = []
    raw_ingredients = [(i, item) for i, items, _ in parts for item in _split_comma_lists(items)]
    raw_steps = [(i, item) for i, _, items in parts for item in items]
    if len(raw_ingredients) > MAX_INGREDIENTS:
        raw_ingredients = raw_ingredients[:MAX_INGREDIENTS]
        warnings.append(DraftWarning(code="too_many_items", message=f"Only the first {MAX_INGREDIENTS} ingredients were kept."))
    if len(raw_steps) > MAX_STEPS:
        raw_steps = raw_steps[:MAX_STEPS]
        warnings.append(DraftWarning(code="too_many_items", message=f"Only the first {MAX_STEPS} steps were kept."))
    for sub_recipe, item in raw_ingredients:
        if (row := _ingredient(item, source, sub_recipe)) is not None:
            ingredients.append(row)
    for sub_recipe, item in raw_steps:
        if (row := _step(item, source, sub_recipe)) is not None:
            steps.append(row)

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

    return DraftContent(
        title=title,
        ingredients=ingredients,
        steps=steps,
        warnings=warnings,
        servings=_servings_in(out.servings, source),
        sub_recipes=sub_recipes,
        **meta,
    )
