"""Unit spellings the validator maps to one canonical form (app/extraction/quantities.py)."""

import pytest

from app.extraction.quantities import canonical_unit


@pytest.mark.parametrize(
    "unit, canonical",
    [("Tablespoons", "tbsp"), ("cup of", "cup"), ("cups  of", "cup"), ("Tbsp.", "tbsp"), ("fl oz", "fl oz"), ("bowl", None), ("bowl of", None)],
)
def test_canonical_unit(unit: str, canonical: str | None) -> None:
    # Seen in the eval baseline: Haiku sometimes returns "cup of" from "one cup of strawberries".
    assert canonical_unit(unit) == canonical
