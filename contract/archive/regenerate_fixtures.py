#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Regenerate deterministic closure proofs for checked-in Jazz Archive fixtures."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any

from validate_archives import FIXTURES_DIR, _jcs_digest, _load_json, _load_ndjson, _text_digest


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n",
        encoding="utf-8",
    )


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _regenerate_fixture(root: Path) -> None:
    manifest_path = root / "manifest.json"
    manifest = _load_json(manifest_path)

    commits_by_capture = {
        item["captureId"]: item for item in manifest.get("captureCommits", [])
    }
    for session_ref in manifest["sessions"]:
        session_path = root / session_ref["path"]
        session = _load_json(session_path)
        capture_id = session["captureId"]
        base = session_path.parent
        records = [
            item
            for item in _load_ndjson(base / "records.ndjson")
            if item.get("captureId") == capture_id
        ]
        artifacts = [
            item
            for item in _load_ndjson(base / "artifacts.ndjson")
            if item.get("captureId") == capture_id
        ]

        commit_ref = commits_by_capture[capture_id]
        commit_path = root / commit_ref["path"]
        commit = _load_json(commit_path)
        observation_lines = [
            f"{item['streamId']}:{item['streamSequence']}:{item['observationId']}:{_jcs_digest(item)}"
            for item in sorted(records, key=lambda item: (item["streamId"], item["streamSequence"]))
        ]
        artifact_lines = [
            f"{item['artifactId']}:{item['content']['sha256']}"
            for item in sorted(artifacts, key=lambda item: item["artifactId"])
        ]
        commit["orderedObservationDigest"] = _text_digest(observation_lines)
        commit["artifactCount"] = len(artifacts)
        commit["artifactSetDigest"] = _text_digest(artifact_lines)
        _write_json(commit_path, commit)

        commit_digest = _jcs_digest(commit)
        commit_ref["digest"] = commit_digest
        session["captureCommit"]["digest"] = commit_digest
        _write_json(session_path, session)

    canonical_files = sorted(
        path
        for path in root.rglob("*")
        if path.is_file()
        and path.relative_to(root).parts[0] != "sync"
        and path.name not in {"manifest.json", "inventory.json"}
    )
    inventory = {
        "algorithm": "sha256",
        "entries": [
            {
                "path": path.relative_to(root).as_posix(),
                "byteLength": path.stat().st_size,
                "sha256": _sha256(path),
            }
            for path in canonical_files
        ],
    }
    inventory_path = root / "inventory.json"
    _write_json(inventory_path, inventory)

    manifest["inventory"]["digest"] = _jcs_digest(inventory)
    unsigned_manifest = {
        key: value for key, value in manifest.items() if key != "contentDigest"
    }
    manifest["contentDigest"] = _jcs_digest(unsigned_manifest)
    _write_json(manifest_path, manifest)


def main() -> int:
    for fixture in sorted(path for path in FIXTURES_DIR.iterdir() if path.is_dir()):
        _regenerate_fixture(fixture)
        print(f"updated {fixture.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
