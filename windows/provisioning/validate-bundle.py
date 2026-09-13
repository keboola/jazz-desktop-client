#!/usr/bin/env python3
"""Validate device-bundle.json without printing secrets."""
from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUNDLE = Path(__file__).resolve().parent / "device-bundle.json"
SCHEMA = ROOT / "contract/enrollment/schema/device-bundle-mvp-v1.schema.json"


def main() -> int:
    if not BUNDLE.is_file():
        print("FAIL: windows/provisioning/device-bundle.json is missing")
        return 1
    try:
        bundle = json.loads(BUNDLE.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        print("FAIL: JSON parse at line", error.lineno)
        return 1
    if not isinstance(bundle, dict):
        print("FAIL: root is not an object")
        return 1

    try:
        import jsonschema
    except ImportError:
        jsonschema = None  # type: ignore
    if jsonschema is not None:
        try:
            jsonschema.validate(bundle, json.loads(SCHEMA.read_text(encoding="utf-8")))
            print("OK: MVP schema")
        except jsonschema.ValidationError as error:
            loc = "/".join(str(part) for part in error.absolute_path) or "<root>"
            print("FAIL: schema at", loc)
            return 1

    fails: list[str] = []

    def req(name: str):
        if name not in bundle:
            fails.append(name + ": missing")
            return None
        return bundle[name]

    if req("enrollmentProfile") != "mvp":
        fails.append("enrollmentProfile: must be mvp")
    if req("kind") != "jazz-device-bundle":
        fails.append("kind: must be jazz-device-bundle")
    project_id = req("projectId")
    if not isinstance(project_id, str) or not project_id.isdigit():
        fails.append("projectId: digits-only string")

    token = req("token")
    if not isinstance(token, str):
        fails.append("token: not a string")
    else:
        separator = token.find("-")
        if separator <= 0 or len(token) - separator - 1 < 16:
            fails.append("token: must be <digits>-<secret> with secret length >= 16")
        elif any(char < "!" or char > "~" for char in token):
            fails.append("token: non-ASCII or whitespace")
        elif any(char < "0" or char > "9" for char in token[:separator]):
            fails.append("token: prefix before dash must be digits")
        else:
            print("OK: token shape (value not shown)")

    expires = req("expiresAt")
    try:
        moment = datetime.fromisoformat(str(expires).replace("Z", "+00:00"))
        if moment <= datetime.now(timezone.utc):
            fails.append("expiresAt: already expired")
        else:
            print("OK: expiresAt in the future")
    except Exception:
        fails.append("expiresAt: not RFC3339")

    for key in ("stackURL", "archiveIngestURL", "streamEndpoint"):
        url = bundle.get(key)
        if not isinstance(url, str):
            fails.append(key + ": missing or not string")
            continue
        if url != url.strip() or "\\" in url or "?" in url or "#" in url:
            fails.append(key + ": whitespace, backslash, query or fragment")
            continue
        if not url.startswith("https://"):
            fails.append(key + ": must be https")
            continue
        if key in ("stackURL", "archiveIngestURL") and url.endswith("/"):
            fails.append(key + ": no trailing slash")
            continue
        if key == "streamEndpoint" and url.rstrip("/").endswith("/v1/logs"):
            fails.append("streamEndpoint: do not include /v1/logs (client appends it)")
            continue
        print("OK:", key, "(value not shown)")

    if fails:
        print("FAIL:")
        for item in fails:
            print(" -", item)
        return 1
    print("OK: client-side checks")
    print("OK: bundle is structurally ready (secrets not printed)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
