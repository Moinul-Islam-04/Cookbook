"""How much users correct the model: saved imports compared with what the model produced.

    python -m app.corrections

For each saved recipe with extracted_content, the model's ingredient and step rows are
compared with the recipe's current rows, then totals are printed per extraction_version.
The recipe's current state is used, so later edits to the recipe count as corrections too.

Rows are matched in order on their text (ingredient raw_text, step instruction) with
difflib: unchanged text is a match; where a run of rows differs, rows are paired in order
and counted as edited, and the rest as added or removed. A matched ingredient whose name,
quantity or unit differs is also edited; "quantities changed" counts matched ingredients
whose quantity differs. Moving a row counts as one removal plus one addition.
"""

from collections import defaultdict
from dataclasses import dataclass, fields
from decimal import Decimal
from difflib import SequenceMatcher

from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.models import Recipe


@dataclass
class Corrections:
    recipes: int = 0
    ingredients_extracted: int = 0
    ingredients_added: int = 0
    ingredients_removed: int = 0
    ingredients_edited: int = 0
    quantities_changed: int = 0
    steps_extracted: int = 0
    steps_added: int = 0
    steps_removed: int = 0
    steps_edited: int = 0

    def add(self, other: "Corrections") -> None:
        for f in fields(self):
            setattr(self, f.name, getattr(self, f.name) + getattr(other, f.name))


def _quantity(value) -> Decimal | None:
    return None if value is None else Decimal(str(value))


def _pairs(old: list[str], new: list[str]) -> tuple[list[tuple[int, int]], int, int]:
    """(matched index pairs, added, removed) for two ordered lists of row texts."""
    matched: list[tuple[int, int]] = []
    added = removed = 0
    for op, i1, i2, j1, j2 in SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        n = min(i2 - i1, j2 - j1) if op in ("equal", "replace") else 0
        matched += [(i1 + k, j1 + k) for k in range(n)]
        removed += (i2 - i1) - n
        added += (j2 - j1) - n
    return matched, added, removed


def compare(extracted: dict, recipe: Recipe) -> Corrections:
    c = Corrections(recipes=1)
    old = extracted["ingredients"]
    new = recipe.ingredients
    c.ingredients_extracted = len(old)
    matched, c.ingredients_added, c.ingredients_removed = _pairs(
        [i["raw_text"] for i in old], [i.raw_text for i in new]
    )
    for i, j in matched:
        a, b = old[i], new[j]
        quantity_changed = _quantity(a.get("quantity")) != _quantity(b.quantity)
        c.quantities_changed += quantity_changed
        c.ingredients_edited += (
            a["raw_text"] != b.raw_text
            or a.get("name") != b.name
            or a.get("unit") != b.unit
            or quantity_changed
        )
    old_steps = [s["instruction"] for s in extracted["steps"]]
    new_steps = [s.instruction for s in recipe.steps]
    c.steps_extracted = len(old_steps)
    matched, c.steps_added, c.steps_removed = _pairs(old_steps, new_steps)
    c.steps_edited = sum(old_steps[i] != new_steps[j] for i, j in matched)
    return c


def report(session: Session) -> dict[str, Corrections]:
    totals: dict[str, Corrections] = defaultdict(Corrections)
    recipes = session.scalars(select(Recipe).where(Recipe.extracted_content.is_not(None)))
    for recipe in recipes:
        totals[recipe.extraction_version or "unknown"].add(compare(recipe.extracted_content, recipe))
    return dict(totals)


def main() -> None:
    settings = get_settings()
    engine = create_engine(settings.database_url, connect_args={"options": "-c timezone=UTC"})
    with Session(engine) as session:
        totals = report(session)
    if not totals:
        print("No saved imports with extracted_content yet.")
    for version, c in sorted(totals.items()):
        print(version)
        for f in fields(c):
            print(f"  {f.name}: {getattr(c, f.name)}")


if __name__ == "__main__":
    main()
