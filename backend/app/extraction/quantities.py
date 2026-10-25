"""Read a leading amount and unit off an ingredient line, e.g. "1 1/2 cups flour".

Used two ways: by the rule-based fallback extractor to split lines, and by the
validator to check that a model's quantity/unit actually appear in the source line.
Spoken amounts ("two tablespoons", from a video transcript) count as amounts too;
vague ones ("a splash", "a handful") never do.
"""

import re
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation

_UNICODE_FRACTIONS = {
    "¼": "1/4", "½": "1/2", "¾": "3/4", "⅓": "1/3", "⅔": "2/3",
    "⅛": "1/8", "⅜": "3/8", "⅝": "5/8", "⅞": "7/8", "⅕": "1/5", "⅙": "1/6",
}

# Units the rule-based splitter recognizes after an amount, singular and plural.
# Matching is case-insensitive and whole-word.
UNITS = {
    "cup", "cups", "c",
    "tbsp", "tbsps", "tablespoon", "tablespoons", "tbs", "tb",
    "tsp", "tsps", "teaspoon", "teaspoons",
    "oz", "ounce", "ounces", "fl oz",
    "lb", "lbs", "pound", "pounds",
    "g", "gram", "grams", "kg", "kilogram", "kilograms",
    "ml", "milliliter", "milliliters", "l", "liter", "liters", "litre", "litres",
    "pinch", "pinches", "dash", "dashes", "clove", "cloves",
    "can", "cans", "pkg", "package", "packages", "stick", "sticks",
    "slice", "slices", "bunch", "bunches", "sprig", "sprigs", "handful", "handfuls",
}

# Spoken amounts in transcripts. "a"/"an" are left out on purpose: "a splash" has no amount.
NUMBER_WORDS = {
    "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
    "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    "half": "1/2", "quarter": "1/4",
}
_NUMBER_WORD = re.compile(r"\b(" + "|".join(NUMBER_WORDS) + r")\b", re.I)

# Canonical spelling for each known unit. A unit outside this table is kept as written
# but flagged for review (validate.py).
UNIT_ALIASES = {
    "cup": "cup", "cups": "cup", "c": "cup",
    "tbsp": "tbsp", "tbsps": "tbsp", "tablespoon": "tbsp", "tablespoons": "tbsp", "tbs": "tbsp", "tb": "tbsp",
    "tsp": "tsp", "tsps": "tsp", "teaspoon": "tsp", "teaspoons": "tsp",
    "oz": "oz", "ounce": "oz", "ounces": "oz", "fl oz": "fl oz",
    "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
    "g": "g", "gram": "g", "grams": "g", "gr": "g", "kg": "kg", "kilogram": "kg", "kilograms": "kg",
    "ml": "ml", "milliliter": "ml", "milliliters": "ml", "millilitre": "ml", "millilitres": "ml",
    "l": "l", "liter": "l", "liters": "l", "litre": "l", "litres": "l",
    "pinch": "pinch", "pinches": "pinch", "dash": "dash", "dashes": "dash",
    "clove": "clove", "cloves": "clove", "can": "can", "cans": "can",
    "pkg": "package", "package": "package", "packages": "package",
    "stick": "stick", "sticks": "stick", "slice": "slice", "slices": "slice",
    "bunch": "bunch", "bunches": "bunch", "sprig": "sprig", "sprigs": "sprig",
    "handful": "handful", "handfuls": "handful", "piece": "piece", "pieces": "piece",
    "head": "head", "heads": "head", "jar": "jar", "jars": "jar", "bag": "bag", "bags": "bag",
    "scoop": "scoop", "scoops": "scoop", "splash": "splash", "drizzle": "drizzle",
}


def canonical_unit(unit: str) -> str | None:
    """"Tablespoons" → "tbsp"; None for a unit outside the known list."""
    return UNIT_ALIASES.get(re.sub(r"\s+", " ", unit.strip().lower().rstrip(".")))


def spell_numbers(text: str) -> str:
    """"two tablespoons" → "2 tablespoons", "half a cup" → "1/2 a cup"."""
    return _NUMBER_WORD.sub(lambda m: NUMBER_WORDS[m.group().lower()], text)


# "1 1/2", "1/2", "1.5", "2", "1½" (after unicode expansion: "1 1/2").
_AMOUNT = re.compile(r"^(?P<amount>\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)(?![\d/.])")
# A range ("2-3 cloves") is ambiguous, so it has no single quantity.
_RANGE = re.compile(r"^\d+(?:[./]\d+)?\s*(?:-|–|to)\s*\d")


def expand_unicode_fractions(text: str) -> str:
    out = text
    for char, frac in _UNICODE_FRACTIONS.items():
        # "1½" → "1 1/2"; a lone "½" → "1/2".
        out = re.sub(rf"(\d){char}", rf"\1 {frac}", out)
        out = out.replace(char, frac)
    return out


def parse_amount(text: str) -> Decimal | None:
    """Value of an amount token ("1 1/2" → 1.5), rounded to the DB's 3 places."""
    try:
        total = Decimal(0)
        for part in text.split():
            if "/" in part:
                num, den = part.split("/")
                if Decimal(den) == 0:
                    return None
                total += Decimal(num) / Decimal(den)
            else:
                total += Decimal(part)
    except (InvalidOperation, ValueError):
        return None
    if total <= 0:
        return None
    return total.quantize(Decimal("0.001"), rounding=ROUND_HALF_UP)


def split_ingredient_line(line: str) -> tuple[Decimal | None, str | None, str]:
    """(quantity, unit, name) for a line like "2 cups flour, sifted".

    Anything unparseable stays in the name with a null quantity/unit, never guessed.
    """
    text = expand_unicode_fractions(line.strip())
    if _RANGE.match(text):
        return None, None, line.strip()
    m = _AMOUNT.match(text)
    if not m:
        return None, None, line.strip()
    quantity = parse_amount(m["amount"])
    rest = text[m.end():].strip()
    unit = None
    words = rest.split()
    if words:
        two = " ".join(words[:2]).lower().rstrip(".,")
        one = words[0].lower().rstrip(".,")
        if two in UNITS:
            unit, rest = " ".join(words[:2]).rstrip(".,"), " ".join(words[2:])
        elif one in UNITS:
            unit, rest = words[0].rstrip(".,"), " ".join(words[1:])
    rest = re.sub(r"^of\s+", "", rest).strip()
    return quantity, unit, rest or line.strip()


def amounts_in(text: str) -> set[Decimal]:
    """Every amount mentioned anywhere in a line, for checking a model's claimed quantity."""
    expanded = spell_numbers(expand_unicode_fractions(text))
    found = set()
    for m in re.finditer(r"\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?", expanded):
        value = parse_amount(m.group())
        if value is not None:
            found.add(value)
    return found
