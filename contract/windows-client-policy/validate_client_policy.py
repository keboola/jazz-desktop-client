#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Validate Jazz Windows client-policy.json fixtures."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parent
SCHEMA_PATH = ROOT / "schema" / "client-policy.schema.json"
FIXTURES_DIR = ROOT / "fixtures"


def main() -> int:
    schema = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
    validator = Draft202012Validator(schema)
    errors: list[str] = []
    for path in sorted(FIXTURES_DIR.glob("*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        for error in sorted(validator.iter_errors(document), key=str):
            errors.append(f"{path.name}: {error.message}")
    if errors:
        for line in errors:
            print(line, file=sys.stderr)
        return 1
    print(f"validated {len(list(FIXTURES_DIR.glob('*.json')))} client-policy fixture(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
