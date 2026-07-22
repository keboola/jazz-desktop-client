#!/usr/bin/env python3
"""Validate the desktop-facing JSON Schemas without depending on either client."""

from __future__ import annotations

import json
import sys
from pathlib import Path

from jsonschema.validators import Draft202012Validator

SCHEMA_DIR = Path(__file__).resolve().parent / "schema"
REQUIRED_KEYS = ("$schema", "$id", "title")
EXPECTED_DIALECT = "https://json-schema.org/draft/2020-12/schema"


def main() -> int:
    failures = 0
    paths = sorted(SCHEMA_DIR.glob("*.schema.json"))
    for path in paths:
        try:
            schema = json.loads(path.read_text(encoding="utf-8"))
            Draft202012Validator.check_schema(schema)
            missing = [key for key in REQUIRED_KEYS if not schema.get(key)]
            if schema.get("$schema") != EXPECTED_DIALECT:
                missing.append("a Draft 2020-12 $schema")
            if missing:
                raise ValueError(f"missing or invalid metadata: {', '.join(missing)}")
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures += 1
            print(f"FAIL  {path.name}: {exc}", file=sys.stderr)
        else:
            print(f"ok    {path.name}")
    if not paths:
        print("FAIL  no schemas found", file=sys.stderr)
        return 1
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
