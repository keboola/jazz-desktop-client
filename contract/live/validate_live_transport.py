#!/usr/bin/env python3
"""Validate live-transport fixtures against their canonical Jazz Archive evidence."""

from __future__ import annotations

import json
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

LIVE_DIR = Path(__file__).resolve().parent
CONTRACT_DIR = LIVE_DIR.parent
ARCHIVE_DIR = CONTRACT_DIR / "archive"
ARCHIVE_FIXTURES_DIR = ARCHIVE_DIR / "fixtures"
FIXTURES_DIR = LIVE_DIR / "fixtures"

sys.path.insert(0, str(ARCHIVE_DIR))
from validate_archives import (  # noqa: E402
    _jcs_digest,
    _load_json,
    _load_ndjson,
    _schemas,
    _validate_fixture,
    _validation_errors,
)


def _canonical_archive_state(
    archive_fixture_name: str,
    schemas: dict[str, dict[str, Any]],
    schemas_by_id: dict[str, dict[str, Any]],
    registry: Registry,
) -> tuple[dict[str, Any], dict[str, Any], dict[str, dict[str, Any]], dict[str, dict[str, Any]], dict[str, Any]]:
    root = ARCHIVE_FIXTURES_DIR / archive_fixture_name
    errors, manifest, _ = _validate_fixture(root, schemas, schemas_by_id, registry)
    if errors or manifest is None:
        detail = "; ".join(errors) if errors else "manifest unavailable"
        raise ValueError(f"archive fixture {archive_fixture_name} is invalid: {detail}")
    if len(manifest["sessions"]) != 1:
        raise ValueError("live conformance fixtures bind exactly one capture")
    session_ref = manifest["sessions"][0]
    session_path = root / session_ref["path"]
    session = _load_json(session_path)
    base = session_path.parent
    records = {
        value["observationId"]: value for value in _load_ndjson(base / "records.ndjson")
    }
    artifacts = {
        value["artifactId"]: value for value in _load_ndjson(base / "artifacts.ndjson")
    }
    commit = _load_json(base / "commit.json")
    return manifest, session, records, artifacts, commit


def _resume_state(
    stream_ids: list[str],
    received_sequences: dict[str, set[int]],
    received_artifact_ids: set[str],
    commit_seen: bool,
    complete: bool,
) -> dict[str, Any]:
    stream_states: list[dict[str, Any]] = []
    for stream_id in sorted(stream_ids):
        accepted = received_sequences.get(stream_id, set())
        next_sequence = 0
        while next_sequence in accepted:
            next_sequence += 1
        stream_states.append(
            {
                "streamId": stream_id,
                "nextSequence": next_sequence,
                "acceptedBeyond": sorted(value for value in accepted if value >= next_sequence),
            }
        )
    return {
        "streams": stream_states,
        "artifactIds": sorted(received_artifact_ids),
        "commitStatus": "accepted" if complete else "incomplete" if commit_seen else "absent",
    }


def validate_live_fixture(value: dict[str, Any]) -> list[str]:
    """Replay a transport transcript and return every fail-closed conformance error."""

    schemas, schemas_by_id, registry = _schemas()
    live_schema = schemas["live-transport-fixture.schema.json"]
    errors = _validation_errors(value, live_schema, "live fixture", registry)
    if errors:
        return errors
    try:
        manifest, session, archive_records, archive_artifacts, archive_commit = (
            _canonical_archive_state(
                value["archiveFixture"], schemas, schemas_by_id, registry
            )
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return [str(exc)]

    for field, expected in (
        ("archiveId", manifest["archiveId"]),
        ("originId", manifest["originId"]),
        ("captureId", session["captureId"]),
    ):
        if value[field] != expected:
            errors.append(f"live {field} differs from canonical archive")

    current_epoch = 0
    last_ack_epoch = 0
    last_ack_state: dict[str, Any] | None = None
    next_delivery_sequence = 0
    last_delivery_sequence = -1
    received_records: dict[str, str] = {}
    received_stream_slots: dict[tuple[str, int], tuple[str, str]] = {}
    received_sequences: dict[str, set[int]] = {}
    received_artifacts: dict[str, str] = {}
    verified_artifact_blobs: dict[str, tuple[str, int]] = {}
    commit_digest: str | None = None
    commit_seen = False
    observation_deliveries = 0
    artifact_deliveries = 0
    duplicate_observation_deliveries = 0
    duplicate_artifact_deliveries = 0
    late_observation_ids: set[str] = set()
    stream_max_seen: dict[str, int] = {}
    final_commit_status = "absent"

    canonical_record_digests = {
        identifier: _jcs_digest(record) for identifier, record in archive_records.items()
    }
    canonical_artifact_digests = {
        identifier: _jcs_digest(artifact) for identifier, artifact in archive_artifacts.items()
    }
    canonical_commit_digest = _jcs_digest(archive_commit)
    stream_ids = list(session["streamIds"])

    for index, message in enumerate(value["messages"]):
        kind = message["kind"]
        epoch = message["epoch"]
        where = f"messages/{index}"
        if kind == "open":
            if epoch != current_epoch + 1:
                errors.append(f"{where}: connection epoch must increase by one")
                continue
            if epoch == 1:
                if "resumesEpoch" in message or "resume" in message:
                    errors.append(f"{where}: first connection must not claim a resume state")
            elif (
                message.get("resumesEpoch") != last_ack_epoch
                or last_ack_state is None
                or message.get("resume") != last_ack_state
            ):
                errors.append(f"{where}: reconnect resume state differs from the last server ack")
            current_epoch = epoch
            next_delivery_sequence = 0
            last_delivery_sequence = -1
            continue

        if epoch != current_epoch or current_epoch == 0:
            errors.append(f"{where}: message belongs to a connection epoch that is not open")
            continue

        if kind not in {"ack", "blob_verified"}:
            delivery_sequence = message["deliverySequence"]
            if delivery_sequence != next_delivery_sequence:
                errors.append(f"{where}: deliverySequence is not contiguous within its epoch")
            next_delivery_sequence = delivery_sequence + 1
            last_delivery_sequence = delivery_sequence

        if kind == "observation":
            observation_deliveries += 1
            record = message["record"]
            identifier = record["observationId"]
            digest = _jcs_digest(record)
            if message["recordDigest"] != digest:
                errors.append(f"{where}: recordDigest does not bind the delivered record")
            canonical_digest = canonical_record_digests.get(identifier)
            if canonical_digest is None or canonical_digest != digest:
                errors.append(f"{where}: observation differs from the canonical archive")
            prior = received_records.get(identifier)
            if prior is not None:
                if prior != digest:
                    errors.append(f"{where}: duplicate observationId has different content")
                else:
                    duplicate_observation_deliveries += 1
            else:
                received_records[identifier] = digest
            slot = (record["streamId"], record["streamSequence"])
            prior_slot = received_stream_slots.get(slot)
            if prior_slot is not None and prior_slot != (identifier, digest):
                errors.append(f"{where}: stream sequence was reused for different content")
            else:
                received_stream_slots[slot] = (identifier, digest)
            stream_id, sequence = slot
            if sequence < stream_max_seen.get(stream_id, sequence):
                late_observation_ids.add(identifier)
            stream_max_seen[stream_id] = max(sequence, stream_max_seen.get(stream_id, sequence))
            received_sequences.setdefault(stream_id, set()).add(sequence)

        elif kind == "artifact":
            artifact_deliveries += 1
            artifact = message["artifact"]
            identifier = artifact["artifactId"]
            digest = _jcs_digest(artifact)
            if message["artifactDigest"] != digest:
                errors.append(f"{where}: artifactDigest does not bind the delivered artifact")
            canonical_digest = canonical_artifact_digests.get(identifier)
            if canonical_digest is None or canonical_digest != digest:
                errors.append(f"{where}: artifact differs from the canonical archive")
            prior = received_artifacts.get(identifier)
            if prior is not None:
                if prior != digest:
                    errors.append(f"{where}: duplicate artifactId has different content")
                else:
                    duplicate_artifact_deliveries += 1
            else:
                received_artifacts[identifier] = digest

        elif kind == "blob_verified":
            identifier = message["artifactId"]
            artifact = archive_artifacts.get(identifier)
            if artifact is None:
                errors.append(f"{where}: verified blob has no canonical artifact")
                continue
            if identifier not in received_artifacts:
                errors.append(f"{where}: blob was verified before its artifact metadata arrived")
                continue
            content = artifact["content"]
            verified = (message["contentSha256"], message["byteLength"])
            canonical = (content["sha256"], content["byteLength"])
            if message["durable"] is not True or verified != canonical:
                errors.append(
                    f"{where}: durable blob receipt differs from canonical sha256 or byteLength"
                )
                continue
            prior = verified_artifact_blobs.get(identifier)
            if prior is not None and prior != verified:
                errors.append(f"{where}: duplicate durable blob receipt has different content")
            else:
                verified_artifact_blobs[identifier] = verified

        elif kind == "commit":
            commit_seen = True
            delivered_commit = message["commit"]
            digest = _jcs_digest(delivered_commit)
            if message["commitDigest"] != digest:
                errors.append(f"{where}: commitDigest does not bind the delivered commit")
            if digest != canonical_commit_digest or delivered_commit != archive_commit:
                errors.append(f"{where}: live CaptureCommit differs from the canonical archive")
            if commit_digest is not None and commit_digest != digest:
                errors.append(f"{where}: duplicate commitId has different content")
            commit_digest = digest

        elif kind == "ack":
            if message["acknowledgedThroughDeliverySequence"] != last_delivery_sequence:
                errors.append(f"{where}: ack does not cover the current epoch delivery prefix")
            complete = (
                set(received_records) == set(archive_records)
                and set(received_artifacts) == set(archive_artifacts)
                and set(verified_artifact_blobs) == set(archive_artifacts)
                and commit_digest == canonical_commit_digest
            )
            expected_state = _resume_state(
                stream_ids,
                received_sequences,
                set(verified_artifact_blobs),
                commit_seen,
                complete,
            )
            if message["state"] != expected_state:
                errors.append(f"{where}: ack state differs from receiver state")
            last_ack_epoch = current_epoch
            last_ack_state = message["state"]
            final_commit_status = expected_state["commitStatus"]

    if set(received_records) != set(archive_records):
        errors.append("live receiver observation set differs from canonical archive")
    if set(received_artifacts) != set(archive_artifacts):
        errors.append("live receiver artifact set differs from canonical archive")
    if set(verified_artifact_blobs) != set(archive_artifacts):
        errors.append("live receiver durable verified blob set differs from canonical archive")
    if commit_digest != canonical_commit_digest or final_commit_status != "accepted":
        errors.append("live receiver did not accept the canonical CaptureCommit")

    actual_outcome = {
        "connectionEpochs": current_epoch,
        "observationDeliveries": observation_deliveries,
        "uniqueObservations": len(received_records),
        "duplicateObservationDeliveries": duplicate_observation_deliveries,
        "artifactDeliveries": artifact_deliveries,
        "uniqueArtifacts": len(received_artifacts),
        "duplicateArtifactDeliveries": duplicate_artifact_deliveries,
        "lateObservationIds": sorted(late_observation_ids),
        "finalCommitStatus": final_commit_status,
    }
    if value["expectedOutcome"] != actual_outcome:
        errors.append("expectedOutcome differs from the replayed delivery outcome")
    return errors


def _negative_self_check(fixture: dict[str, Any]) -> None:
    duplicate_conflict = deepcopy(fixture)
    observations = [
        message for message in duplicate_conflict["messages"] if message["kind"] == "observation"
    ]
    first_by_id: dict[str, dict[str, Any]] = {}
    duplicate = next(
        candidate
        for candidate in observations
        if candidate["record"]["observationId"] in first_by_id
        or not first_by_id.setdefault(candidate["record"]["observationId"], candidate)
    )
    duplicate["record"]["capturedAt"] = "2026-07-23T00:00:00Z"
    duplicate["recordDigest"] = _jcs_digest(duplicate["record"])
    errors = validate_live_fixture(duplicate_conflict)
    if not any("duplicate observationId has different content" in error for error in errors):
        raise ValueError("negative self-check: duplicate ID with different content was accepted")

    reconnect_mismatch = deepcopy(fixture)
    reconnect = next(
        message
        for message in reconnect_mismatch["messages"]
        if message["kind"] == "open" and message["epoch"] > 1
    )
    reconnect["resume"]["streams"][0]["nextSequence"] += 1
    errors = validate_live_fixture(reconnect_mismatch)
    if not any("reconnect resume state differs" in error for error in errors):
        raise ValueError("negative self-check: reconnect mismatch was accepted")

    metadata_only_ack = deepcopy(fixture)
    first_ack = next(message for message in metadata_only_ack["messages"] if message["kind"] == "ack")
    audio_artifact = next(
        message["artifact"]["artifactId"]
        for message in metadata_only_ack["messages"]
        if message["kind"] == "artifact" and message["artifact"]["kind"] == "meeting_audio"
    )
    first_ack["state"]["artifactIds"].append(audio_artifact)
    first_ack["state"]["artifactIds"].sort()
    errors = validate_live_fixture(metadata_only_ack)
    if not any("ack state differs from receiver state" in error for error in errors):
        raise ValueError("negative self-check: artifact metadata was acknowledged as blob bytes")


def main() -> int:
    try:
        schemas, _, registry = _schemas()
        resources = [
            (schema["$id"], Resource.from_contents(schema))
            for schema in schemas.values()
            if isinstance(schema.get("$id"), str)
        ]
        local_registry = Registry().with_resources(resources)
        live_schema = schemas["live-transport-fixture.schema.json"]
        Draft202012Validator(
            live_schema, registry=local_registry, format_checker=FormatChecker()
        )
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL  schemas: {exc}", file=sys.stderr)
        return 1

    fixture_paths = sorted(FIXTURES_DIR.glob("*.json"))
    if not fixture_paths:
        print("FAIL  no live transport fixtures found", file=sys.stderr)
        return 1
    failures = 0
    for path in fixture_paths:
        try:
            fixture = _load_json(path)
            errors = validate_live_fixture(fixture)
            if errors:
                failures += 1
                print(f"FAIL  {path.name}", file=sys.stderr)
                for error in errors:
                    print(f"      {error}", file=sys.stderr)
                continue
            _negative_self_check(fixture)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures += 1
            print(f"FAIL  {path.name}: {exc}", file=sys.stderr)
        else:
            print(f"ok    {path.name}")
    return int(failures > 0)


if __name__ == "__main__":
    raise SystemExit(main())
