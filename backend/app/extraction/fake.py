"""Deterministic, offline extractors: no model, no network, no cost.

`RuleBasedExtractor` reads common caption layouts (an "Ingredients" header, bullet or
numbered lines). It's the development default, so the import flow works end to end
before any LLM is chosen. `FakeExtractor` returns canned outputs for known captions
(test fixtures) and falls back to the rule-based one for everything else.
"""

import json
import re
from collections.abc import Callable

from app.extraction.base import ExtractionOutput, RawIngredient, RawStep
from app.extraction.quantities import split_ingredient_line

_INGREDIENT_HEADER = re.compile(r"^\W*(ingredients?|you(?:'|’)ll need|what you need)\W*$", re.I)
_STEP_HEADER = re.compile(
    r"^\W*(instructions?|directions?|method|steps?|how to make( it)?|preparation)\W*$", re.I
)
_BULLET = re.compile(r"^\s*(?:[-–•*▪︎●◦]|\d+[.)]|step\s*\d+\s*[:.)-]?)\s*", re.I)
_HASHTAG_LINE = re.compile(r"^(\s*#\w+\s*)+$")
_EMOJI = re.compile("[\U0001f300-\U0001faff☀-➿️]")


def _clean(line: str) -> str:
    return _EMOJI.sub("", line).strip()


class RuleBasedExtractor:
    version = "rules-1"

    def extract(self, source_text: str) -> str:
        lines = [_clean(l) for l in source_text.splitlines()]
        lines = [l for l in lines if l and not _HASHTAG_LINE.match(l)]

        title = None
        section = None
        ingredients: list[RawIngredient] = []
        steps: list[RawStep] = []
        for line in lines:
            if _INGREDIENT_HEADER.match(line):
                section = "ingredients"
                continue
            if _STEP_HEADER.match(line):
                section = "steps"
                continue
            body = _BULLET.sub("", line).strip()
            if not body:
                continue
            if section is None:
                # Before any header: a short first line is the title; the rest is chatter.
                if title is None and len(body) <= 80:
                    title = body.rstrip(":").strip()
                continue
            if section == "ingredients":
                quantity, unit, name = split_ingredient_line(body)
                ingredients.append(
                    RawIngredient(
                        raw_text=body,
                        name=name,
                        quantity=float(quantity) if quantity is not None else None,
                        unit=unit,
                    )
                )
            else:
                steps.append(RawStep(instruction=body))

        output = ExtractionOutput(
            is_recipe=bool(ingredients or steps),
            title=title if (ingredients or steps) else None,
            ingredients=ingredients,
            steps=steps,
        )
        return output.model_dump_json()


class FakeExtractor:
    """Canned responses keyed by exact caption; a callable can raise or stall."""

    version = "fake-1"

    def __init__(
        self,
        responses: dict[str, str | Callable[[], str]] | None = None,
        fallback: RuleBasedExtractor | None = None,
    ) -> None:
        self.responses = responses or {}
        self.fallback = fallback or RuleBasedExtractor()
        self.calls: list[str] = []

    def extract(self, source_text: str) -> str:
        self.calls.append(source_text)
        response = self.responses.get(source_text)
        if response is None:
            return self.fallback.extract(source_text)
        if callable(response):
            return response()
        return response if isinstance(response, str) else json.dumps(response)
