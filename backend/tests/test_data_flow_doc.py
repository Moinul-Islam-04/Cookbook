"""docs/DATA_FLOW.md names files and functions; fail when one of them moves or is renamed."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOC = (ROOT / "docs" / "DATA_FLOW.md").read_text()


def _resolve(path: str) -> Path:
    for base in (ROOT, ROOT / "backend"):
        if (base / path).exists():
            return base / path
    raise AssertionError(f"docs/DATA_FLOW.md names a missing file: {path}")


def test_every_file_and_function_in_the_doc_exists() -> None:
    # Table cells like `app/ingest/tiktok.py` · `normalize_tiktok`
    pairs = re.findall(r"`([\w/.-]+\.(?:py|swift))` · `(\w+)`", DOC)
    assert len(pairs) >= 15
    for path, name in pairs:
        source = _resolve(path).read_text()
        assert re.search(rf"\b(?:def|class|func|struct|enum)\s+{name}\b", source), f"{name} not in {path}"
    for path in set(re.findall(r"`((?:app|ios|backend)/[\w/.-]+\.(?:py|swift|md))`", DOC)):
        if "backend/evals" not in path:  # added by the evals slice
            _resolve(path)
