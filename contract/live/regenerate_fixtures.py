#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Regenerate the live reconnect golden from canonical archive objects."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

LIVE_DIR = Path(__file__).resolve().parent
CONTRACT_DIR = LIVE_DIR.parent
ARCHIVE_DIR = CONTRACT_DIR / "archive"
ARCHIVE_ROOT = ARCHIVE_DIR / "fixtures" / "04-meeting-screen-share"
CAPTURE_ID = "cap-44444444-4444-7444-8444-444444444441"
SESSION_ROOT = ARCHIVE_ROOT / "sessions" / CAPTURE_ID

sys.path.insert(0, str(ARCHIVE_DIR))
from validate_archives import _jcs_digest, _load_json, _load_ndjson  # noqa: E402


def _observation(epoch: int, sequence: int, record: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "observation",
        "epoch": epoch,
        "deliverySequence": sequence,
        "recordDigest": _jcs_digest(record),
        "record": record,
    }


def _artifact(epoch: int, sequence: int, artifact: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "artifact",
        "epoch": epoch,
        "deliverySequence": sequence,
        "artifactDigest": _jcs_digest(artifact),
        "artifact": artifact,
    }


def _blob_verified(epoch: int, artifact: dict[str, Any]) -> dict[str, Any]:
    content = artifact["content"]
    return {
        "kind": "blob_verified",
        "epoch": epoch,
        "artifactId": artifact["artifactId"],
        "contentSha256": content["sha256"],
        "byteLength": content["byteLength"],
        "durable": True,
    }


def _commit(epoch: int, sequence: int, commit: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "commit",
        "epoch": epoch,
        "deliverySequence": sequence,
        "commitDigest": _jcs_digest(commit),
        "commit": commit,
    }


def main() -> int:
    manifest = _load_json(ARCHIVE_ROOT / "manifest.json")
    session = _load_json(SESSION_ROOT / "session.json")
    records = {
        value["observationId"]: value
        for value in _load_ndjson(SESSION_ROOT / "records.ndjson")
    }
    artifacts = {
        value["artifactId"]: value
        for value in _load_ndjson(SESSION_ROOT / "artifacts.ndjson")
    }
    commit = _load_json(SESSION_ROOT / "commit.json")

    video_stream, audio_stream, transcript_stream, control_stream = session["streamIds"]
    video_0 = records["obs-44444444-4444-7444-8444-444444444441"]
    late_video_1 = records["obs-44444444-4444-7444-8444-444444444442"]
    video_2 = records["obs-44444444-4444-7444-8444-444444444443"]
    audio_0 = records["obs-44444444-4444-7444-8444-444444444444"]
    transcript_0 = records["obs-44444444-4444-7444-8444-444444444445"]
    controls = [
        records[f"obs-44444444-4444-7444-8444-44444444444{suffix}"]
        for suffix in ("6", "7", "8", "9", "a", "b", "c", "d")
    ]
    video_artifact = artifacts["art-44444444-4444-7444-8444-444444444441"]
    audio_artifact = artifacts["art-44444444-4444-7444-8444-444444444442"]
    transcript_artifact = artifacts["art-44444444-4444-7444-8444-444444444443"]

    incomplete_state = {
        "streams": [
            {"streamId": video_stream, "nextSequence": 1, "acceptedBeyond": [2]},
            {"streamId": audio_stream, "nextSequence": 1, "acceptedBeyond": []},
            {"streamId": transcript_stream, "nextSequence": 0, "acceptedBeyond": []},
            {"streamId": control_stream, "nextSequence": 5, "acceptedBeyond": []},
        ],
        "artifactIds": [video_artifact["artifactId"]],
        "commitStatus": "incomplete",
    }
    complete_state = {
        "streams": [
            {"streamId": video_stream, "nextSequence": 3, "acceptedBeyond": []},
            {"streamId": audio_stream, "nextSequence": 1, "acceptedBeyond": []},
            {"streamId": transcript_stream, "nextSequence": 1, "acceptedBeyond": []},
            {"streamId": control_stream, "nextSequence": 8, "acceptedBeyond": []},
        ],
        "artifactIds": sorted(artifacts),
        "commitStatus": "accepted",
    }

    fixture = {
        "protocol": "dev.jazz.live-capture",
        "protocolVersion": 1,
        "archiveFixture": "04-meeting-screen-share",
        "archiveId": manifest["archiveId"],
        "originId": manifest["originId"],
        "captureId": session["captureId"],
        "messages": [
            {"kind": "open", "epoch": 1},
            _observation(1, 0, video_0),
            _observation(1, 1, video_2),
            _observation(1, 2, audio_0),
            _observation(1, 3, controls[0]),
            _observation(1, 4, controls[1]),
            _observation(1, 5, controls[2]),
            _observation(1, 6, controls[3]),
            _observation(1, 7, controls[4]),
            _artifact(1, 8, video_artifact),
            _artifact(1, 9, audio_artifact),
            _blob_verified(1, video_artifact),
            _commit(1, 10, commit),
            {
                "kind": "ack",
                "epoch": 1,
                "acknowledgedThroughDeliverySequence": 10,
                "state": incomplete_state,
            },
            {"kind": "open", "epoch": 2, "resumesEpoch": 1, "resume": incomplete_state},
            _observation(2, 0, video_2),
            _observation(2, 1, audio_0),
            _observation(2, 2, controls[4]),
            _artifact(2, 3, video_artifact),
            _observation(2, 4, late_video_1),
            _observation(2, 5, controls[5]),
            _observation(2, 6, controls[6]),
            _observation(2, 7, controls[7]),
            _observation(2, 8, transcript_0),
            _artifact(2, 9, transcript_artifact),
            _blob_verified(2, audio_artifact),
            _blob_verified(2, transcript_artifact),
            _commit(2, 10, commit),
            {
                "kind": "ack",
                "epoch": 2,
                "acknowledgedThroughDeliverySequence": 10,
                "state": complete_state,
            },
        ],
        "expectedOutcome": {
            "connectionEpochs": 2,
            "observationDeliveries": 16,
            "uniqueObservations": 13,
            "duplicateObservationDeliveries": 3,
            "artifactDeliveries": 4,
            "uniqueArtifacts": 3,
            "duplicateArtifactDeliveries": 1,
            "lateObservationIds": [late_video_1["observationId"]],
            "finalCommitStatus": "accepted",
        },
    }
    destination = LIVE_DIR / "fixtures" / "01-reconnect-late-media.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        json.dumps(fixture, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n",
        encoding="utf-8",
    )
    print(f"updated {destination.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
