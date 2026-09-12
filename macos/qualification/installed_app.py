#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Read-only S5 preflight. Never launches/signals the app, reads credentials or grants permission.

Run with --receipt NEW_PATH. The receipt is observation, not approval to Start/Stop/relaunch.
No queue entry, package, preference, TCC setting or installed-app file is written.
"""

from __future__ import annotations

import argparse
from collections import Counter
from datetime import UTC, datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess

APP = Path("/Applications/Jazz Capture.app")
EXECUTABLE = APP / "Contents/MacOS/JazzCapture"
PILOT_SHA256 = "4ec1e731a217e314d53ccf2ece6d23c646f342c6a044e4ced566d0575e2e0737"
REQUIREMENT = 'identifier "dev.jazz.capture" and certificate leaf = H"f8361a52b8430f36d775bd025e097e92997a809a"'
STATES = frozenset(
    {
        "queued",
        "creatingIntent",
        "uploading",
        "finalizing",
        "verifying",
        "processing",
        "ready",
        "retryable",
        "reconnectRequired",
        "failed_terminal",
        "rejected",
        "quarantined",
        "conflict",
        "cancelled",
    }
)
AUTOMATIC = frozenset(
    {
        "queued",
        "creatingIntent",
        "uploading",
        "finalizing",
        "verifying",
        "processing",
        "retryable",
    }
)


def archive_queue_snapshot(root: Path) -> dict:
    """Bounded metadata-only inventory. Absence/error/changes never prove safe delivery state."""
    counts: Counter[str] = Counter()
    try:
        if root.is_symlink() or not root.is_dir():
            raise ValueError("unknown root")
        for index, path in enumerate(root.iterdir()):
            if index >= 1024:
                raise ValueError("inventory cap")
            if path.suffix != ".json":
                continue
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, "rb") as source:
                before = os.fstat(source.fileno())
                if not stat.S_ISREG(before.st_mode) or before.st_size > 131072:
                    raise ValueError("record limit")
                raw = source.read(131073)
                after = os.fstat(source.fileno())
            if len(raw) > 131072 or (before.st_size, before.st_mtime_ns) != (
                after.st_size,
                after.st_mtime_ns,
            ):
                raise ValueError("changed record")
            state = json.loads(raw)["state"]
            if state not in STATES:
                raise ValueError("unknown state")
            counts[state] += 1
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        return {"inventoryComplete": False, "allDeliveryQueuesSafe": False}
    return {
        "inventoryComplete": True,
        "observedStates": dict(sorted(counts.items())),
        "automaticCandidates": sum(counts[s] for s in AUTOMATIC),
        # Other spools and concurrent producers are outside this snapshot. No quiescence claim.
        "allDeliveryQueuesSafe": False,
    }


def matching_pids(ps_output: str) -> list[int]:
    matches = []
    for line in ps_output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and parts[0].isdigit() and parts[1] == str(EXECUTABLE):
            matches.append(int(parts[0]))
    return matches


def assessment(provenance: bool, pids: list[int] | None, queue: dict) -> dict:
    blockers = []
    if not provenance:
        blockers.append("installed_pilot_provenance_not_verified")
    blockers.append(
        "app_not_running" if pids == [] else "visible_recording_state_not_verified"
    )
    if queue.get("automaticCandidates", 0):
        blockers.append("archive_delivery_may_resume_on_launch")
    blockers.extend(
        [
            "all_delivery_queues_not_attested_safe",
            "controlled_visible_native_trial_required",
        ]
    )
    return {
        "processState": "unknown"
        if pids is None
        else "not_running"
        if not pids
        else "running",
        "blockers": blockers,
        "s5Qualified": False,
        "visibleStateQualified": False,
        "startStopPauseQualified": False,
        "installedTCCAndMaskingQualified": False,
        "sampledMediaQualified": False,
        "idleRelaunchInterruptionQualified": False,
        "resourceBoundsQualified": False,
        "actionsPerformed": [],
    }


def collect() -> dict:
    observed = {"observedAt": datetime.now(UTC).isoformat(), "bundlePath": str(APP)}
    try:
        with (APP / "Contents/Info.plist").open("rb") as source:
            raw = source.read(1_048_577)
        if len(raw) > 1_048_576:
            raise ValueError("metadata limit")
        info = plistlib.loads(raw)
        if not isinstance(info, dict):
            raise ValueError("metadata shape")
        with EXECUTABLE.open("rb") as source:
            digest = hashlib.file_digest(source, "sha256").hexdigest()
        verified = (
            subprocess.run(
                [
                    "/usr/bin/codesign",
                    "--verify",
                    "--deep",
                    "--strict",
                    "-R",
                    "=" + REQUIREMENT,
                    str(APP),
                ],
                capture_output=True,
                timeout=30,
                check=False,
            ).returncode
            == 0
        )
        observed.update(
            {
                "version": info.get("CFBundleShortVersionString"),
                "build": info.get("CFBundleVersion"),
                "executableSHA256": digest,
                "pinnedSignatureValid": verified,
            }
        )
        provenance = (
            verified
            and digest == PILOT_SHA256
            and info.get("CFBundleIdentifier") == "dev.jazz.capture"
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        provenance = False
    try:
        process = subprocess.run(
            ["/bin/ps", "-axo", "pid=,comm="],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        pids = matching_pids(process.stdout)
    except (OSError, subprocess.SubprocessError):
        pids = None
    queue = archive_queue_snapshot(
        Path.home() / ".jazz/spool/archive-upload-delivery/records"
    )
    return {
        **observed,
        "provenanceMatchesPilot": provenance,
        "matchingPids": pids,
        "archiveQueue": queue,
        **assessment(provenance, pids, queue),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    args = parser.parse_args()
    destination = args.receipt.parent.resolve() / args.receipt.name
    protected = [APP.resolve(), (Path.home() / ".jazz").resolve()]
    if any(destination == root or root in destination.parents for root in protected):
        parser.error("receipt must be outside the installed app and capture data")
    # Reserve exclusively before inspection; never overwrite a prior receipt or follow a link.
    fd = os.open(
        destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600
    )
    with os.fdopen(fd, "w") as output:
        json.dump(collect(), output, indent=2)
        output.write("\n")
    print("Read-only snapshot saved; S5 remains unqualified. No app actions performed.")


if __name__ == "__main__":
    main()
