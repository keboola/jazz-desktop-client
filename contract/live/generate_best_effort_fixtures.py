#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Deterministic alternate-mode vectors; no signing key, live capture or archive mutation."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

CONTRACT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(CONTRACT))
from archive.validate_archives import _jcs  # noqa: E402


def digest(value: object) -> str:
    return hashlib.sha256(_jcs(value).encode()).hexdigest()


def generated() -> bytes:
    old = json.loads(sorted((CONTRACT / "live/otlp-fixtures").glob("*.json"))[0].read_text())
    cap = {"schemaVersion": 1, "capability": "dev.jazz.best-effort.v1", "sourceId": "jazz-synthetic-source",
        "ongoingTransmission": True, "lossPolicy": "volatile-network-crash-overload-v1", "lateInputPolicy": "successorOnly",
        "fidelity": "sampledActivity", "coverage": "unknown", "expiresAt": "2026-07-22T10:00:00Z"}
    common = {"protocol": "dev.jazz.best-effort", "protocolVersion": 1, "coverage": "unknown", "authority": "provisional"}
    epoch = {**common, "documentType": "epoch", "epochId": "bep-11111111-1111-7111-8111-111111111111",
        "originId": old["originId"], "captureId": old["captureId"], "binding": {
            "stackURL": "https://connection.europe-west3.gcp.keboola.com", "projectId": "999999",
            "scope": {"companyId": "synthetic", "areaId": "synthetic", "deviceId": "synthetic"},
            "sourceId": cap["sourceId"], "bundleId": "jdb_" + "1" * 32, "generation": 7},
        "capability": cap, "startedAt": "2026-07-22T09:00:00Z"}
    # Reuse the exact canonical evidence codec as an alternate synthetic mode, never dual-publish.
    items = [old["items"][0], next(item for item in old["items"] if item["kind"] == "artifact")]
    rows = [{**common, "documentType": "envelope", "epochId": epoch["epochId"], "epochDigest": digest(epoch),
        "item": item, "mediaState": "notExpected" if item["kind"] == "observation" else "pending"} for item in items]
    selection = {**common, "documentType": "inputSelection", "epochId": epoch["epochId"], "epochDigest": digest(epoch),
        "items": sorted([{"itemId": r["item"]["itemId"], "envelopeDigest": digest(r)} for r in rows], key=lambda r: r["itemId"]),
        "analysisEligibility": "blocked", "archiveReady": False}
    selection["selectionId"] = "bes-" + digest(selection)
    attrs = [{"jazz.best_effort.version": 1, "jazz.best_effort.epoch": epoch["epochId"],
        "jazz.best_effort.canonical": _jcs(r), "jazz.best_effort.digest": digest(r)} for r in rows]
    requests = []
    for row, attributes in zip(rows, attrs):
        delta = datetime.fromisoformat(row["item"]["capturedAt"].replace("Z", "+00:00")) - datetime(1970, 1, 1, tzinfo=timezone.utc)
        nanos = str((delta.days * 86400 + delta.seconds) * 1_000_000_000 + delta.microseconds * 1000)
        log = {"timeUnixNano": nanos, "observedTimeUnixNano": nanos, "severityText": "INFO", "severityNumber": 9,
            "traceId": "", "spanId": "", "body": {"stringValue": "jazz.best_effort.provisional"},
            "attributes": [{"key": key, "value": {"intValue" if type(value) is int else "stringValue": str(value)}} for key, value in attributes.items()]}
        requests.append({"resourceLogs": [{"resource": {"attributes": []}, "scopeLogs": [{"scope": {"name": "dev.jazz.best-effort"}, "logRecords": [log]}]}]})
    pins = {"epoch:" + epoch["epochId"]: digest(epoch), "capture:" + epoch["captureId"]: digest(epoch)}
    for row in rows:
        item = row["item"]
        pins["item:" + item["itemId"]] = digest(row)
        if item["kind"] == "observation":
            pins[f"slot:{epoch['captureId']}:{item['streamId']}:{item['streamSequence']}"] = digest(row)
    return (json.dumps({"capability": cap, "epoch": epoch, "envelopes": rows, "selection": selection,
        "identityPins": pins, "otlpAttributes": attrs, "otlpRequests": requests}, indent=2, ensure_ascii=False) + "\n").encode()


def check() -> None:
    expected = generated()
    for path in paths():
        if path.read_bytes() != expected:
            raise ValueError("best-effort golden drift: " + path.name)


def paths() -> tuple[Path, Path]:
    return (CONTRACT / "live/best-effort/fixtures/01-provisional.json",
        CONTRACT.parent / "macos/Tests/JazzCaptureCoreTests/Fixtures/best-effort-v1.json")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--check", action="store_true")
    if parser.parse_args().check:
        check()
    else:
        for path in paths():
            path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(generated())
