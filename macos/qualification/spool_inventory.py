#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Read-only full ~/.jazz inventory. Hashes evidence; never replays WALs or takes writer locks."""

from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sqlite3
import stat
import subprocess

from installed_app import APP, collect

FAMILIES = frozenset(
    {
        "archives",
        "journal",
        "shots",
        "narration",
        "archive-artifact-delivery",
        "archive-upload-delivery",
        "capture-coach-live",
        "guided-execution",
    }
)
LIFECYCLES = frozenset(
    {"idle", "starting", "recording", "closingInput", "draining", "committed"}
)


def scan(root: Path) -> dict:
    entries = []
    families: dict[str, Counter] = {}
    lifecycle: Counter = Counter()
    locks = 0
    wal = 0
    intent = None
    total = 0
    if root.is_symlink() or not root.is_dir():
        raise ValueError("inventory root unavailable")

    def reject_walk_error(error: OSError) -> None:
        raise error

    for directory, children, files in os.walk(
        root, followlinks=False, onerror=reject_walk_error
    ):
        for name in sorted(children + files):
            path = Path(directory) / name
            rel = path.relative_to(root)
            before = path.lstat()
            mode = before.st_mode
            if not (stat.S_ISDIR(mode) or stat.S_ISREG(mode)):
                raise ValueError("symlink or special entry")
            if len(entries) >= 50000:
                raise ValueError("entry ceiling")
            digest = None
            raw = b""
            if stat.S_ISREG(mode):
                total += before.st_size
                if total > 8 * 1024**3:
                    raise ValueError("byte ceiling")
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    opened = os.fstat(stream.fileno())
                    if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                        raise ValueError("entry replaced")
                    hasher = hashlib.sha256()
                    remaining = before.st_size
                    while remaining:
                        chunk = stream.read(min(65536, remaining))
                        if not chunk:
                            raise ValueError("entry truncated")
                        hasher.update(chunk)
                        remaining -= len(chunk)
                    if stream.read(1):
                        raise ValueError("entry grew")
                    digest = hasher.hexdigest()
                    if (
                        name in {"state.json", "capture-intent.json"}
                        and before.st_size <= 1048576
                    ):
                        stream.seek(0)
                        raw = stream.read(1048577)
                    after = os.fstat(stream.fileno())
                if (before.st_size, before.st_mtime_ns) != (
                    after.st_size,
                    after.st_mtime_ns,
                ):
                    raise ValueError("entry changed")
                parts = rel.parts
                family = (
                    parts[1]
                    if len(parts) > 1 and parts[0] == "spool" and parts[1] in FAMILIES
                    else "other"
                )
                family_counts = families.setdefault(family, Counter())
                family_counts["files"] += 1
                family_counts["bytes"] += before.st_size
                locks += int("lock" in name.lower())
                wal += int("wal" in parts)
                if raw:
                    try:
                        value = json.loads(raw)
                        if name == "capture-intent.json":
                            intent = {
                                k: value[k]
                                for k in ["version", "userPaused", "runGuard"]
                                if k in value and type(value[k]) in (int, bool)
                            }
                        else:
                            state = value.get("lifecycle")
                            lifecycle[
                                state
                                if isinstance(state, str) and state in LIFECYCLES
                                else "unknown"
                            ] += 1
                    except (ValueError, TypeError, AttributeError, RecursionError):
                        lifecycle["unreadable"] += 1
            entries.append(
                [
                    hashlib.sha256(str(rel).encode()).hexdigest(),
                    "directory" if stat.S_ISDIR(mode) else "file",
                    before.st_size,
                    before.st_mtime_ns,
                    before.st_ino,
                    digest,
                ]
            )
    for family in FAMILIES:
        families.setdefault(family, Counter(files=0, bytes=0))
    entries.sort()
    encoded = json.dumps(entries, separators=(",", ":")).encode()
    return {
        "treeSHA256": hashlib.sha256(encoded).hexdigest(),
        "entries": len(entries),
        "bytes": total,
        "families": {k: dict(v) for k, v in sorted(families.items())},
        "checkpointLifecycles": dict(lifecycle),
        "walFiles": wal,
        "lockFiles": locks,
        "captureIntent": intent,
        "walReplayed": False,
    }


def tcc_snapshot(path: Path) -> dict:
    """Never create SQLite WAL/SHM. A live WAL makes an immutable-base reading non-current."""
    try:
        if not path.is_file():
            return {"status": "unavailable"}
        if path.with_name(path.name + "-wal").exists():
            return {"status": "not_read_live_wal", "effectivePermissionsKnown": False}
        before = path.stat()
        with sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True) as conn:
            rows = conn.execute(
                "SELECT service, auth_value FROM access WHERE client = ?",
                ("dev.jazz.capture",),
            ).fetchall()
        if (before.st_mtime_ns, before.st_size) != (
            path.stat().st_mtime_ns,
            path.stat().st_size,
        ):
            return {"status": "changed"}
        allowed = {
            "kTCCServiceAccessibility",
            "kTCCServiceScreenCapture",
            "kTCCServiceMicrophone",
            "kTCCServiceListenEvent",
        }
        return {
            "status": "base_store_observed",
            "storedValues": {s: v for s, v in rows if s in allowed and type(v) is int},
            "effectivePermissionsKnown": False,
        }
    except (OSError, sqlite3.Error):
        return {"status": "unavailable", "effectivePermissionsKnown": False}


def review_heads(root: Path) -> dict:
    """Inspect archive-level assertion chains without invoking finalization/recovery code."""
    counts: Counter = Counter()
    errors = []
    missing_queue = 0
    reviews = root / "spool/archives/.review"
    if not reviews.exists():
        return {"heads": {}, "confirmedWithoutQueue": 0}
    for directory in reviews.iterdir():
        if not directory.is_dir() or directory.is_symlink():
            raise ValueError("invalid review directory")
        values = []
        for path in (directory / "assertions").glob("*.json"):
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as source:
                if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                    raise ValueError("invalid review file")
                raw = source.read(1048577)
            if len(raw) > 1048576:
                raise ValueError("review limit")
            value = json.loads(raw)
            if value.get("scope") == "archive" and value.get("target") == {
                "kind": "archive",
                "id": directory.name,
            }:
                item = {
                    k: value.get(k) for k in ("assertionId", "supersedes", "decision")
                }
                if (
                    not isinstance(item["assertionId"], str)
                    or len(item["assertionId"]) > 128
                    or (
                        item["supersedes"] is not None
                        and (
                            not isinstance(item["supersedes"], str)
                            or len(item["supersedes"]) > 128
                        )
                    )
                ):
                    raise ValueError("review identity limit")
                values.append(item)
        if not values:
            continue
        by_id = {v["assertionId"]: v for v in values}
        prior = [v["supersedes"] for v in values if v.get("supersedes") is not None]
        heads = set(by_id) - set(prior)
        if (
            len(by_id) != len(values)
            or len(prior) != len(set(prior))
            or not set(prior) <= set(by_id)
            or len(heads) != 1
        ):
            errors.append(
                {
                    "blocker": "ambiguous_review_chain",
                    "archiveIdSHA256": hashlib.sha256(
                        directory.name.encode()
                    ).hexdigest(),
                    "assertions": len(values),
                    "heads": len(heads),
                    "missingPredecessors": len(set(prior) - set(by_id)),
                    "duplicatePredecessors": len(prior) - len(set(prior)),
                }
            )
            continue
        head = by_id[next(iter(heads))]
        seen = set()
        cursor = head
        while cursor:
            if cursor["assertionId"] in seen:
                raise ValueError("review cycle")
            seen.add(cursor["assertionId"])
            cursor = by_id.get(cursor.get("supersedes"))
        if len(seen) != len(values) or head.get("decision") not in {
            "confirm",
            "reject",
            "correct",
        }:
            raise ValueError("invalid review chain")
        counts[head["decision"]] += 1
        if (
            head["decision"] == "confirm"
            and not (
                root
                / "spool/archive-upload-delivery/records"
                / (directory.name + ".json")
            ).is_file()
        ):
            missing_queue += 1
    return {
        "valid": not errors,
        "heads": dict(counts),
        "confirmedWithoutQueue": missing_queue,
        "errors": errors,
    }


def inventory(root: Path) -> dict:
    result = {"complete": False, "controlledLaunchAllowed": False}
    try:
        first = scan(root)
        try:
            reviews = {"valid": True, **review_heads(root)}
        except (
            OSError,
            ValueError,
            TypeError,
            KeyError,
            AttributeError,
            RecursionError,
        ):
            reviews = {
                "valid": False,
                "blocker": "review_chain_unreadable_or_ambiguous",
            }
        second = scan(root)
        result.update(second)
        result["archiveReview"] = reviews
        result["complete"] = first == second
        result["twoPassStable"] = first == second
        result["semanticChecksComplete"] = bool(reviews["valid"])
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        result["blocker"] = "inventory_unavailable_changed_or_limit_exceeded"
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    root = Path.home() / ".jazz"
    destination = args.receipt.parent.resolve() / args.receipt.name
    if any(
        p == destination or p in destination.parents
        for p in [root.resolve(), APP.resolve()]
    ):
        parser.error("receipt cannot be written to capture data or installed app")
    fd = os.open(
        destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(fd, "w") as output:
        result = {"installed": collect(), "inventory": inventory(root)}
        preferences = Path.home() / "Library/Preferences/dev.jazz.capture.plist"
        try:
            with preferences.open("rb") as source:
                value = plistlib.load(source)
            result["storedPreferences"] = {
                k: value[k]
                for k in [
                    "continuousCapture",
                    "reconnectOnLaunch",
                    "captureSetupLocalOnly.v1",
                ]
                if type(value.get(k)) is bool
            }
            policy = value.get("captureDeliveryPolicy")
            result["storedPreferences"]["captureDeliveryPolicy"] = (
                policy
                if policy in {"confirmedArchive", "liveCompatibility"}
                else "absent_or_unknown"
            )
        except (OSError, ValueError, AttributeError, TypeError):
            result["storedPreferences"] = {"status": "unavailable"}
        result["preferencesAreEffectivePolicyProof"] = False
        result["tcc"] = {
            "user": tcc_snapshot(
                Path.home() / "Library/Application Support/com.apple.TCC/TCC.db"
            ),
            "system": tcc_snapshot(
                Path("/Library/Application Support/com.apple.TCC/TCC.db")
            ),
        }
        try:
            handles = subprocess.run(
                ["/usr/sbin/lsof", "-F", "pf", "+D", str(root)],
                capture_output=True,
                text=True,
                timeout=30,
            )
            result["openHandleObservation"] = {
                "pids": [
                    int(s[1:])
                    for s in handles.stdout.splitlines()
                    if s.startswith("p") and s[1:].isdigit()
                ],
                "fileDescriptors": sum(
                    s.startswith("f") for s in handles.stdout.splitlines()
                ),
                "diagnosticsPresent": bool(handles.stderr),
                "exitCode": handles.returncode,
                "exclusiveLockFreedomProven": False,
            }
        except (OSError, subprocess.SubprocessError):
            result["openHandleObservation"] = {
                "status": "unavailable",
                "exclusiveLockFreedomProven": False,
            }
        result["launchBlockers"] = [
            "review_chain_integrity_not_proven",
            "retained_reconnect_required_delivery_with_launch_reconnect_path",
            "effective_delivery_authority_not_proven_inert",
            "effective_installed_TCC_not_observed",
        ]
        result["actionsPerformed"] = []
        json.dump(result, output, indent=2)
        output.write("\n")
    print(
        "Inventory saved. No locks acquired, WAL replay, app launch or capture action."
    )


if __name__ == "__main__":
    main()
