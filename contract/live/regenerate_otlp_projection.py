#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Regenerate the canonical liveCompatibility OTLP mapping golden from one Jazz Archive."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

LIVE_DIR = Path(__file__).resolve().parent
ARCHIVE_DIR = LIVE_DIR.parent / "archive"
ARCHIVE_FIXTURE = "02-labeled-narration"
ARCHIVE_ROOT = ARCHIVE_DIR / "fixtures" / ARCHIVE_FIXTURE

sys.path.insert(0, str(ARCHIVE_DIR))
from validate_archives import _jcs, _jcs_digest, _load_json, _load_ndjson  # noqa: E402


def _captured_at(kind: str, document: dict[str, Any]) -> str:
    if kind == "observation":
        return str(document["capturedAt"])
    if kind == "artifact":
        interval = document.get("captureInterval")
        if isinstance(interval, dict) and isinstance(interval.get("startedAt"), str):
            return interval["startedAt"]
        derivation = document.get("derivation")
        if isinstance(derivation, dict) and isinstance(derivation.get("computedAt"), str):
            return derivation["computedAt"]
        raise ValueError("artifact has no canonical capture/derivation time")
    return str(document["endedAt"])


def _item(kind: str, document: dict[str, Any]) -> dict[str, Any]:
    identity_field = {
        "observation": "observationId",
        "artifact": "artifactId",
        "commit": "commitId",
    }[kind]
    value: dict[str, Any] = {
        "kind": kind,
        "itemId": document[identity_field],
        "canonicalDigest": _jcs_digest(document),
        "canonicalJcs": _jcs(document),
        "capturedAt": _captured_at(kind, document),
    }
    if kind == "observation":
        value.update(
            {
                "streamId": document["streamId"],
                "streamSequence": document["streamSequence"],
                "recordType": document["recordType"],
            }
        )
    return value


def main() -> int:
    manifest = _load_json(ARCHIVE_ROOT / "manifest.json")
    if len(manifest["sessions"]) != 1:
        raise ValueError("OTLP mapping golden requires exactly one capture")
    session_path = ARCHIVE_ROOT / manifest["sessions"][0]["path"]
    session = _load_json(session_path)
    base = session_path.parent
    records = _load_ndjson(base / "records.ndjson")
    artifacts_path = base / "artifacts.ndjson"
    artifacts = _load_ndjson(artifacts_path) if artifacts_path.is_file() else []
    commit = _load_json(base / "commit.json")
    fixture = {
        "protocol": "dev.jazz.live-otlp-projection",
        "protocolVersion": 1,
        "archiveFixture": ARCHIVE_FIXTURE,
        "archiveId": manifest["archiveId"],
        "originId": manifest["originId"],
        "captureId": session["captureId"],
        "items": [
            *(_item("observation", record) for record in records),
            *(_item("artifact", artifact) for artifact in artifacts),
            _item("commit", commit),
        ],
    }
    destination = LIVE_DIR / "otlp-fixtures" / "01-canonical-projection.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n",
        encoding="utf-8",
    )
    print(f"updated {destination.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
