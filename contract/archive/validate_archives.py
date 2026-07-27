#!/usr/bin/env python3
"""Validate Jazz archive fixtures: schemas, references, layers, and closure proofs."""

from __future__ import annotations

import hashlib
import json
import math
import sys
import unicodedata
from copy import deepcopy
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

ARCHIVE_DIR = Path(__file__).resolve().parent
CONTRACT_DIR = ARCHIVE_DIR.parent
FIXTURES_DIR = ARCHIVE_DIR / "fixtures"

ACTIVITY_EVENT_SCHEMA_ID = "https://jasnost.dev/schema/activity-event.schema.json"
COACH_INTERACTION_SCHEMA_ID = "https://jasnost.dev/schema/coach-interaction.schema.json"
MEDIA_OBSERVATION_SCHEMA_ID = "https://jasnost.dev/schema/media-observation.schema.json"
MEETING_CONTROL_OBSERVATION_SCHEMA_ID = (
    "https://jasnost.dev/schema/meeting-control-observation.schema.json"
)
CAPTURE_CAPABILITY_OBSERVATION_SCHEMA_ID = (
    "https://jasnost.dev/schema/capture-capability-observation.schema.json"
)
SUPPORTED_PAYLOAD_CONTRACTS: dict[tuple[str, str, int], str] = {
    ("jazz.activity-event", ACTIVITY_EVENT_SCHEMA_ID, 1): ACTIVITY_EVENT_SCHEMA_ID,
    ("jazz.coach-interaction", COACH_INTERACTION_SCHEMA_ID, 1): COACH_INTERACTION_SCHEMA_ID,
    ("jazz.media-observation", MEDIA_OBSERVATION_SCHEMA_ID, 1): MEDIA_OBSERVATION_SCHEMA_ID,
    (
        "jazz.meeting-control-observation",
        MEETING_CONTROL_OBSERVATION_SCHEMA_ID,
        1,
    ): MEETING_CONTROL_OBSERVATION_SCHEMA_ID,
    (
        "jazz.capture-capability-observation",
        CAPTURE_CAPABILITY_OBSERVATION_SCHEMA_ID,
        1,
    ): CAPTURE_CAPABILITY_OBSERVATION_SCHEMA_ID,
}


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, child in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON object key: {key}")
        value[key] = child
    return value


def _reject_nonfinite_constant(value: str) -> None:
    raise ValueError(f"non-I-JSON number literal: {value}")


def _parse_json(text: str) -> Any:
    return json.loads(
        text,
        object_pairs_hook=_reject_duplicate_keys,
        parse_constant=_reject_nonfinite_constant,
    )


def _load_json(path: Path) -> dict[str, Any]:
    value = _parse_json(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("expected a JSON object")
    return value


def _load_ndjson(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    rows: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        value = _parse_json(line)
        if not isinstance(value, dict):
            raise ValueError(f"{path.name}:{line_number}: expected a JSON object")
        rows.append(value)
    return rows


def _schemas() -> tuple[dict[str, dict[str, Any]], dict[str, dict[str, Any]], Registry]:
    by_name: dict[str, dict[str, Any]] = {}
    by_id: dict[str, dict[str, Any]] = {}
    resources: list[tuple[str, Resource[Any]]] = []
    for path in sorted(CONTRACT_DIR.rglob("*.schema.json")):
        schema = _load_json(path)
        schema_id = schema.get("$id")
        if not isinstance(schema_id, str) or not schema_id:
            raise ValueError(f"{path}: missing $id")
        if schema_id in by_id:
            raise ValueError(f"duplicate schema $id: {schema_id}")
        by_name[path.name] = schema
        by_id[schema_id] = schema
        resources.append((schema_id, Resource.from_contents(schema)))
    return by_name, by_id, Registry().with_resources(resources)


def _validation_errors(
    value: Any, schema: dict[str, Any], label: str, registry: Registry
) -> list[str]:
    validator = Draft202012Validator(schema, registry=registry, format_checker=FormatChecker())
    errors: list[str] = []
    for error in sorted(validator.iter_errors(value), key=lambda item: str(item.absolute_path)):
        where = "/" + "/".join(str(part) for part in error.absolute_path)
        errors.append(f"{label}{where}: {error.message}")
    return errors


def _schema_errors(
    value: Any, schema_name: str, schemas: dict[str, dict[str, Any]], registry: Registry
) -> list[str]:
    return _validation_errors(value, schemas[schema_name], schema_name, registry)


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _jcs_number(value: int | float) -> str:
    """Serialize an I-JSON number with ECMAScript/JCS formatting (RFC 8785 section 3.2.2.3)."""
    if isinstance(value, int):
        if abs(value) > 9_007_199_254_740_991:
            raise ValueError("JCS integer is outside the I-JSON safe integer range")
        return str(value)
    if not math.isfinite(value):
        raise ValueError("JCS forbids NaN and infinity")
    if value == 0:
        return "0"

    rendered = repr(value).lower()
    sign = ""
    if rendered.startswith("-"):
        sign, rendered = "-", rendered[1:]
    if "e" in rendered:
        mantissa, exponent_text = rendered.split("e", 1)
        exponent = int(exponent_text)
    else:
        mantissa, exponent = rendered, 0
    if "." in mantissa:
        whole, fraction = mantissa.split(".", 1)
    else:
        whole, fraction = mantissa, ""
    digits = (whole + fraction).lstrip("0") or "0"
    decimal_exponent = exponent - len(fraction)
    while len(digits) > 1 and digits.endswith("0"):
        digits = digits[:-1]
        decimal_exponent += 1
    scientific_exponent = len(digits) + decimal_exponent - 1

    if -6 <= scientific_exponent < 21:
        point = len(digits) + decimal_exponent
        if point <= 0:
            body = "0." + ("0" * -point) + digits
        elif point >= len(digits):
            body = digits + ("0" * (point - len(digits)))
        else:
            body = digits[:point] + "." + digits[point:]
    else:
        body = digits[0]
        if len(digits) > 1:
            body += "." + digits[1:]
        body += "e" + ("+" if scientific_exponent >= 0 else "") + str(scientific_exponent)
    return sign + body


def _jcs(value: Any) -> str:
    """Return the RFC 8785 JSON Canonicalization Scheme representation."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, (int, float)):
        return _jcs_number(value)
    if isinstance(value, str):
        value.encode("utf-8")  # Reject lone surrogate code points.
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if isinstance(value, list):
        return "[" + ",".join(_jcs(item) for item in value) + "]"
    if isinstance(value, dict):
        if not all(isinstance(key, str) for key in value):
            raise ValueError("JCS object keys must be strings")
        keys = sorted(value, key=lambda key: key.encode("utf-16-be"))
        return "{" + ",".join(f"{_jcs(key)}:{_jcs(value[key])}" for key in keys) + "}"
    raise ValueError(f"unsupported JCS value: {type(value).__name__}")


def _jcs_digest(value: Any) -> str:
    return hashlib.sha256(_jcs(value).encode("utf-8")).hexdigest()


def _jcs_self_check() -> None:
    """Check against RFC 8785 sections 3.2.2/3.2.3 before trusting any fixture hash."""
    primitive_source = r'''{
      "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
      "string": "\u20ac$\u000F\u000aA'\u0042\u0022\u005c\\\"\/",
      "literals": [null, true, false]
    }'''
    primitive_expected = (
        r'''{"literals":[null,true,false],"numbers":[333333333.3333333,1e+30,4.5,0.002,1e-27],"string":"€$\u000f\nA'B\"\\\\\"/"}'''
    )
    primitive = json.loads(primitive_source)
    if _jcs(primitive) != primitive_expected:
        raise ValueError("JCS implementation fails RFC 8785 primitive canonicalization vector")
    if _jcs_digest(primitive) != "2d5e01a318d0f0879ab568c4be289c8b1f64ef8921a53c6277d5e069978baacb":
        raise ValueError("JCS implementation fails RFC 8785 primitive SHA-256 vector")

    sorting = {
        "\u20ac": "Euro Sign",
        "\r": "Carriage Return",
        "\ufb33": "Hebrew Letter Dalet With Dagesh",
        "1": "One",
        "\U0001f600": "Emoji: Grinning Face",
        "\u0080": "Control",
        "\u00f6": "Latin Small Letter O With Diaeresis",
    }
    sorting_expected = (
        '{"\\r":"Carriage Return","1":"One","\u0080":"Control","ö":"Latin Small Letter O With Diaeresis",'
        '"€":"Euro Sign","😀":"Emoji: Grinning Face","דּ":"Hebrew Letter Dalet With Dagesh"}'
    )
    if _jcs(sorting) != sorting_expected:
        raise ValueError("JCS implementation fails RFC 8785 UTF-16 property-order vector")
    if _jcs({"integer": 9_007_199_254_740_991}) != '{"integer":9007199254740991}':
        raise ValueError("JCS implementation fails the I-JSON safe integer boundary")
    for unsafe in (9_007_199_254_740_992, -9_007_199_254_740_992):
        try:
            _jcs({"integer": unsafe})
        except ValueError:
            continue
        raise ValueError("JCS implementation accepted an integer outside the I-JSON safe range")


def _text_digest(lines: list[str]) -> str:
    return hashlib.sha256("".join(f"{line}\n" for line in lines).encode("utf-8")).hexdigest()


def _safe_path(root: Path, relative: str) -> Path:
    candidate = root / relative
    if not candidate.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"path escapes archive root: {relative}")
    current = root
    for part in Path(relative).parts:
        current /= part
        if current.is_symlink():
            raise ValueError(f"path traverses a symlink: {relative}")
    return candidate


def _portable_path_collision_errors(paths: list[str], label: str) -> list[str]:
    errors: list[str] = []
    by_portable_key: dict[str, str] = {}
    for path in paths:
        # relativePath is ASCII-only, so case-folding is the only normalization that can still
        # collide across supported filesystems.
        key = path.casefold()
        prior = by_portable_key.get(key)
        if prior is not None and prior != path:
            errors.append(f"{label} contains case-colliding paths {prior} and {path}")
        else:
            by_portable_key[key] = path
    return errors


def _content_digest_errors(manifest: dict[str, Any]) -> list[str]:
    content_digest = manifest.get("contentDigest")
    if content_digest is None:
        if manifest.get("state") == "finalized":
            return ["a finalized manifest must contain contentDigest"]
        return []
    manifest_without_content_digest = {
        key: value for key, value in manifest.items() if key != "contentDigest"
    }
    expected = _jcs_digest(manifest_without_content_digest)
    if content_digest != expected:
        return [
            "contentDigest must equal sha256(JCS(manifest without contentDigest)); "
            f"expected {expected}"
        ]
    return []


def _payload_contract_key(contract: dict[str, Any]) -> tuple[str, str, int] | None:
    record_type = contract.get("recordType")
    schema_id = contract.get("schemaId")
    schema_version = contract.get("schemaVersion")
    if not isinstance(record_type, str) or not isinstance(schema_id, str):
        return None
    if not isinstance(schema_version, int) or isinstance(schema_version, bool):
        return None
    return record_type, schema_id, schema_version


def _resolve_payload_contract(
    contract: dict[str, Any], schemas_by_id: dict[str, dict[str, Any]]
) -> tuple[dict[str, Any] | None, str | None]:
    catalog_key = _payload_contract_key(contract)
    installed_schema_id = SUPPORTED_PAYLOAD_CONTRACTS.get(catalog_key)
    if installed_schema_id is None:
        return None, f"unsupported payload contract {catalog_key}; schema URIs are not fetched"
    schema = schemas_by_id.get(installed_schema_id)
    if schema is None:
        return None, f"payload contract schema is not installed locally: {catalog_key}"
    return schema, None


def _digested_identity_conflicts(prior_digest: str | None, candidate_digest: str) -> bool:
    return prior_digest is not None and prior_digest != candidate_digest


def _provenance_sources(value: dict[str, Any]) -> set[str]:
    provenance = value.get("provenance")
    if not isinstance(provenance, dict):
        return set()
    sources = provenance.get("sources")
    return {str(item) for item in sources} if isinstance(sources, list) else set()


def _contains_key(value: Any, forbidden: set[str]) -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in forbidden:
                return key
            found = _contains_key(child, forbidden)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _contains_key(child, forbidden)
            if found:
                return found
    return None


def _target_exists(kind: str, identifier: str, ids: dict[str, set[str]]) -> bool:
    plural = {
        "archive": "archives",
        "capture": "captures",
        "commit": "commits",
        "label": "labels",
        "observation": "observations",
        "artifact": "artifacts",
        "assertion": "assertions",
        "actor": "actors",
        "source": "sources",
    }.get(kind)
    return plural is not None and identifier in ids.get(plural, set())


def _media_observation_errors(
    record: dict[str, Any],
    actors_by_id: dict[str, dict[str, Any]],
    sources_by_id: dict[str, dict[str, Any]],
    artifacts_by_id: dict[str, dict[str, Any]],
) -> list[str]:
    """Validate cross-document invariants that a payload-only JSON Schema cannot express."""

    if record.get("recordType") != "jazz.media-observation":
        return []
    observation_id = record.get("observationId")
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return [f"media observation {observation_id} payload must be an object"]

    errors: list[str] = []
    artifact_id = payload.get("artifactId")
    artifact_role = payload.get("artifactRole")
    matching_artifact_refs = [
        ref
        for ref in record.get("artifactRefs", [])
        if ref.get("artifactId") == artifact_id and ref.get("role") == artifact_role
    ]
    if len(matching_artifact_refs) != 1:
        errors.append(
            f"media observation {observation_id} payload artifact must match exactly one envelope artifactRef"
        )
    artifact = artifacts_by_id.get(str(artifact_id))
    if artifact is not None and artifact.get("kind") != artifact_role:
        errors.append(
            f"media observation {observation_id} artifact kind differs from its canonical role"
        )

    source_time = payload.get("sourceTime")
    monotonic = record.get("monotonicTime")
    if not isinstance(source_time, dict) or not isinstance(monotonic, dict):
        errors.append(f"media observation {observation_id} needs envelope and payload source time")
    else:
        for envelope_key, payload_key in (
            ("ticks", "startTicks"),
            ("unit", "unit"),
            ("clockId", "clockId"),
            ("clockDomainId", "clockDomainId"),
            ("bootId", "bootId"),
        ):
            if monotonic.get(envelope_key) != source_time.get(payload_key):
                errors.append(
                    f"media observation {observation_id} envelope monotonicTime differs from sourceTime"
                )
                break
        try:
            if int(str(source_time.get("endTicks"))) < int(str(source_time.get("startTicks"))):
                errors.append(f"media observation {observation_id} ends before it starts")
        except ValueError:
            errors.append(f"media observation {observation_id} has invalid source ticks")

        source_refs = {
            str(ref.get("sourceId")) for ref in record.get("sourceRefs", []) if ref.get("sourceId")
        }
        matching_clock = any(
            isinstance(sources_by_id.get(source_id, {}).get("clock"), dict)
            and sources_by_id[source_id]["clock"].get("monotonicClock")
            == source_time.get("clockId")
            and sources_by_id[source_id]["clock"].get("clockDomainId")
            == source_time.get("clockDomainId")
            and sources_by_id[source_id]["clock"].get("bootId") == source_time.get("bootId")
            for source_id in source_refs
        )
        if not matching_clock:
            errors.append(
                f"media observation {observation_id} sourceTime has no matching declared source clock"
            )

    attribution = payload.get("attribution")
    if not isinstance(attribution, dict):
        return errors
    identity_roles = {"performer", "participant", "speaker"}
    identity_refs = [
        ref for ref in record.get("actorRefs", []) if ref.get("role") in identity_roles
    ]
    status = attribution.get("status")
    if status in {"identified", "anonymous"}:
        actor_id = attribution.get("actorId")
        actor = actors_by_id.get(str(actor_id))
        expected_identity_status = "identified" if status == "identified" else "anonymous"
        if actor is None or actor.get("identityStatus") != expected_identity_status:
            errors.append(
                f"media observation {observation_id} attribution is not backed by a matching actor identity"
            )
        if not any(
            ref.get("actorId") == actor_id and ref.get("basis") == attribution.get("basis")
            for ref in identity_refs
        ):
            errors.append(
                f"media observation {observation_id} attribution is not backed by an actorRef"
            )
    elif status == "unknown":
        guessed = [
            ref.get("actorId")
            for ref in identity_refs
            if actors_by_id.get(str(ref.get("actorId")), {}).get("identityStatus") != "unknown"
        ]
        if guessed:
            errors.append(
                f"media observation {observation_id} unknown participant was guessed from another identity"
            )
    return errors


def _meeting_control_observation_errors(
    record: dict[str, Any],
    session: dict[str, Any] | None,
    actors_by_id: dict[str, dict[str, Any]],
    sources_by_id: dict[str, dict[str, Any]],
) -> list[str]:
    """Validate lifecycle evidence against declared clocks, identities, and consent policy."""

    if record.get("recordType") != "jazz.meeting-control-observation":
        return []
    observation_id = record.get("observationId")
    payload = record.get("payload")
    if not isinstance(payload, dict):
        return [f"meeting control {observation_id} payload must be an object"]

    errors: list[str] = []
    monotonic = record.get("monotonicTime")
    source_refs = {
        str(ref.get("sourceId")) for ref in record.get("sourceRefs", []) if ref.get("sourceId")
    }
    matching_metadata_source = any(
        isinstance(sources_by_id.get(source_id, {}).get("clock"), dict)
        and isinstance(sources_by_id.get(source_id, {}).get("capabilities"), list)
        and "meeting.metadata" in sources_by_id[source_id]["capabilities"]
        and isinstance(monotonic, dict)
        and sources_by_id[source_id]["clock"].get("monotonicClock")
        == monotonic.get("clockId")
        and sources_by_id[source_id]["clock"].get("clockDomainId")
        == monotonic.get("clockDomainId")
        and sources_by_id[source_id]["clock"].get("bootId") == monotonic.get("bootId")
        for source_id in source_refs
    )
    if not matching_metadata_source:
        errors.append(
            f"meeting control {observation_id} has no matching meeting.metadata source clock"
        )
    if record.get("artifactRefs"):
        errors.append(f"meeting control {observation_id} must not cite a media artifact")
    if record.get("interactionContext") is not None or record.get("legacyCorrelation") is not None:
        errors.append(f"meeting control {observation_id} carries desktop-only context")

    attribution = payload.get("participantAttribution")
    if isinstance(attribution, dict):
        identity_refs = [
            ref
            for ref in record.get("actorRefs", [])
            if ref.get("role") in {"performer", "participant", "speaker"}
        ]
        status = attribution.get("status")
        if status in {"identified", "anonymous"}:
            actor_id = attribution.get("actorId")
            actor = actors_by_id.get(str(actor_id))
            expected = "identified" if status == "identified" else "anonymous"
            if actor is None or actor.get("identityStatus") != expected:
                errors.append(
                    f"meeting control {observation_id} attribution lacks matching actor identity"
                )
            if not any(
                ref.get("actorId") == actor_id
                and ref.get("basis") == attribution.get("basis")
                for ref in identity_refs
            ):
                errors.append(
                    f"meeting control {observation_id} attribution lacks matching actorRef"
                )
        elif status == "unknown" and any(
            actors_by_id.get(str(ref.get("actorId")), {}).get("identityStatus") != "unknown"
            for ref in identity_refs
        ):
            errors.append(
                f"meeting control {observation_id} unknown participant was guessed"
            )

    consent = payload.get("consent")
    if isinstance(consent, dict) and session is not None:
        capture_policy = session.get("capturePolicy")
        privacy = record.get("privacy")
        if not isinstance(capture_policy, dict) or not isinstance(privacy, dict):
            errors.append(f"meeting control {observation_id} consent lacks policy context")
        else:
            policy = consent.get("policyVersion")
            if policy != capture_policy.get("policyVersion") or policy != privacy.get(
                "policyVersion"
            ):
                errors.append(
                    f"meeting control {observation_id} consent policy is not capture-bound"
                )
            modalities = consent.get("modalities")
            policy_modalities = capture_policy.get("modalities")
            if (
                not isinstance(modalities, list)
                or modalities != sorted(set(modalities))
                or not isinstance(policy_modalities, list)
                or not set(modalities).issubset(set(policy_modalities))
            ):
                errors.append(
                    f"meeting control {observation_id} consent modalities are invalid"
                )

    epoch = payload.get("connectionEpoch")
    resumed = payload.get("resumesEpoch")
    if resumed is not None and (
        not isinstance(epoch, int)
        or isinstance(epoch, bool)
        or not isinstance(resumed, int)
        or isinstance(resumed, bool)
        or resumed >= epoch
    ):
        errors.append(f"meeting control {observation_id} has an invalid reconnect epoch")
    return errors


def _meeting_control_timeline_errors(records: list[dict[str, Any]]) -> list[str]:
    """Validate the canonical consent, connection, presence, and share state machine."""

    controls = [
        record
        for record in records
        if record.get("recordType") == "jazz.meeting-control-observation"
    ]
    if not controls:
        return []
    errors: list[str] = []
    by_capture: dict[str, list[dict[str, Any]]] = {}
    for record in controls:
        by_capture.setdefault(str(record.get("captureId")), []).append(record)

    for capture_id, capture_controls in by_capture.items():
        stream_ids = {str(record.get("streamId")) for record in capture_controls}
        if len(stream_ids) != 1:
            errors.append(f"meeting control capture {capture_id} must use one canonical stream")
            continue
        ordered = sorted(
            capture_controls,
            key=lambda record: (
                int(record.get("streamSequence", -1)),
                str(record.get("observationId")),
            ),
        )
        event_ids = [
            record.get("payload", {}).get("controlEventId")
            for record in ordered
            if isinstance(record.get("payload"), dict)
        ]
        if len(event_ids) != len(set(event_ids)):
            errors.append(f"meeting control capture {capture_id} reuses a controlEventId")

        consent_granted = False
        last_epoch: int | None = None
        connected = False
        active_participants: set[str] = set()
        active_tracks: set[str] = set()
        for record in ordered:
            observation_id = record.get("observationId")
            payload = record.get("payload")
            if not isinstance(payload, dict):
                continue
            event_type = payload.get("eventType")
            if event_type == "consent_granted":
                if consent_granted:
                    errors.append(f"meeting control {observation_id} duplicates consent grant")
                consent_granted = True
            elif event_type == "consent_revoked":
                if not consent_granted:
                    errors.append(f"meeting control {observation_id} revokes absent consent")
                consent_granted = False
            elif event_type == "producer_connected":
                epoch = payload.get("connectionEpoch")
                if not consent_granted or connected:
                    errors.append(
                        f"meeting control {observation_id} connects outside consent/disconnect state"
                    )
                if last_epoch is None:
                    if epoch != 1 or payload.get("resumesEpoch") is not None:
                        errors.append(
                            f"meeting control {observation_id} has invalid initial connection"
                        )
                elif (
                    not isinstance(epoch, int)
                    or isinstance(epoch, bool)
                    or epoch <= last_epoch
                    or payload.get("resumesEpoch") != last_epoch
                ):
                    errors.append(
                        f"meeting control {observation_id} does not resume the prior epoch"
                    )
                if isinstance(epoch, int) and not isinstance(epoch, bool):
                    last_epoch = epoch
                connected = True
            elif event_type == "producer_disconnected":
                if (
                    not consent_granted
                    or not connected
                    or payload.get("connectionEpoch") != last_epoch
                ):
                    errors.append(
                        f"meeting control {observation_id} disconnects a non-current epoch"
                    )
                connected = False
            elif event_type == "participant_joined":
                participant_id = payload.get("participantInstanceId")
                if (
                    not consent_granted
                    or not connected
                    or not isinstance(participant_id, str)
                    or participant_id in active_participants
                ):
                    errors.append(
                        f"meeting control {observation_id} has invalid participant join state"
                    )
                elif isinstance(participant_id, str):
                    active_participants.add(participant_id)
            elif event_type == "participant_left":
                participant_id = payload.get("participantInstanceId")
                if (
                    not consent_granted
                    or not connected
                    or not isinstance(participant_id, str)
                    or participant_id not in active_participants
                ):
                    errors.append(
                        f"meeting control {observation_id} has invalid participant leave state"
                    )
                elif isinstance(participant_id, str):
                    active_participants.remove(participant_id)
            elif event_type == "screen_share_started":
                track_id = payload.get("trackId")
                if (
                    not consent_granted
                    or not connected
                    or not isinstance(track_id, str)
                    or track_id in active_tracks
                ):
                    errors.append(
                        f"meeting control {observation_id} has invalid screen-share start state"
                    )
                elif isinstance(track_id, str):
                    active_tracks.add(track_id)
            elif event_type == "screen_share_stopped":
                track_id = payload.get("trackId")
                if (
                    not consent_granted
                    or not connected
                    or not isinstance(track_id, str)
                    or track_id not in active_tracks
                ):
                    errors.append(
                        f"meeting control {observation_id} has invalid screen-share stop state"
                    )
                elif isinstance(track_id, str):
                    active_tracks.remove(track_id)

        if last_epoch is None:
            errors.append(f"meeting control capture {capture_id} has no producer connection")
        if active_participants:
            errors.append(
                f"meeting control capture {capture_id} leaves participants active "
                f"{sorted(active_participants)}"
            )
        if active_tracks:
            errors.append(
                f"meeting control capture {capture_id} leaves screen shares active "
                f"{sorted(active_tracks)}"
            )
    return errors


def _label_semantic_key(label: dict[str, Any]) -> tuple[str, ...]:
    binding = label.get("processBinding")
    if isinstance(binding, dict):
        return (
            "process",
            str(binding.get("areaId", "")).strip().casefold(),
            str(binding.get("processId", "")).strip().casefold(),
        )
    declaration = label.get("declaration")
    raw = declaration.get("text", "") if isinstance(declaration, dict) else ""
    folded = unicodedata.normalize("NFKD", str(raw).casefold())
    normalized = "".join(char for char in folded if not unicodedata.combining(char))
    return ("declaration", " ".join(normalized.split()))


def _label_lineage_errors(
    labels: list[dict[str, Any]],
    records_by_id: dict[str, dict[str, Any]],
) -> list[str]:
    """Validate a causal, linear chain without inventing order across streams."""

    errors: list[str] = []
    labels_by_id = {
        str(label.get("labelId")): label
        for label in labels
        if isinstance(label.get("labelId"), str)
    }
    successor_by_predecessor: dict[str, str] = {}
    for label in labels:
        label_id = str(label.get("labelId"))
        lineage = label.get("lineage")
        if not isinstance(lineage, dict):
            continue
        baseline_id = str(lineage.get("baselineLabelId"))
        baseline = labels_by_id.get(baseline_id)
        baseline_lineage = baseline.get("lineage") if isinstance(baseline, dict) else None
        if (
            baseline is None
            or baseline.get("captureId") != label.get("captureId")
            or not isinstance(baseline_lineage, dict)
            or baseline_lineage.get("baselineLabelId") != baseline_id
            or baseline_lineage.get("resumesLabelId") is not None
            or _label_semantic_key(baseline) != _label_semantic_key(label)
        ):
            errors.append(f"label {label_id} has an invalid lineage baseline")
            continue

        resumes_id = lineage.get("resumesLabelId")
        if resumes_id is None:
            if baseline_id != label_id:
                errors.append(f"label {label_id} omits its lineage predecessor")
            continue
        predecessor = labels_by_id.get(str(resumes_id))
        predecessor_lineage = (
            predecessor.get("lineage") if isinstance(predecessor, dict) else None
        )
        predecessor_start = (
            records_by_id.get(predecessor.get("interval", {}).get("startObservationId"))
            if isinstance(predecessor, dict)
            else None
        )
        current_start = records_by_id.get(
            label.get("interval", {}).get("startObservationId")
        )
        if (
            resumes_id == label_id
            or predecessor is None
            or predecessor.get("captureId") != label.get("captureId")
            or not isinstance(predecessor_lineage, dict)
            or predecessor_lineage.get("baselineLabelId") != baseline_id
            or _label_semantic_key(predecessor) != _label_semantic_key(label)
            or predecessor_start is None
            or current_start is None
            or predecessor_start.get("streamId") != current_start.get("streamId")
            or not isinstance(predecessor_start.get("streamSequence"), int)
            or not isinstance(current_start.get("streamSequence"), int)
            or predecessor_start["streamSequence"] >= current_start["streamSequence"]
        ):
            errors.append(f"label {label_id} has an invalid lineage predecessor")
            continue
        prior_successor = successor_by_predecessor.get(str(resumes_id))
        if prior_successor is not None and prior_successor != label_id:
            errors.append(
                f"label {resumes_id} has branched successors "
                f"{prior_successor} and {label_id}"
            )
        else:
            successor_by_predecessor[str(resumes_id)] = label_id
    return errors


def _validate_inventory(
    root: Path,
    manifest: dict[str, Any],
    schemas: dict[str, dict[str, Any]],
    registry: Registry,
) -> list[str]:
    errors: list[str] = []
    inventory_meta = manifest["inventory"]
    if inventory_meta.get("path") != "inventory.json":
        errors.append("manifest inventory path must be root inventory.json")
    try:
        inventory_path = _safe_path(root, inventory_meta["path"])
        inventory = _load_json(inventory_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return [f"inventory: {exc}"]

    errors.extend(_schema_errors(inventory, "archive-inventory.schema.json", schemas, registry))
    actual_inventory_digest = _jcs_digest(inventory)
    if inventory_meta["digest"] != actual_inventory_digest:
        errors.append(
            f"manifest inventory digest {inventory_meta['digest']} != {actual_inventory_digest}"
        )
    errors.extend(_content_digest_errors(manifest))
    if inventory.get("algorithm") != "sha256" or not isinstance(inventory.get("entries"), list):
        return errors + ["inventory must contain algorithm=sha256 and an entries array"]

    listed: set[str] = set()
    for index, entry in enumerate(inventory["entries"]):
        if not isinstance(entry, dict):
            errors.append(f"inventory entry {index} is not an object")
            continue
        try:
            relative = str(entry["path"])
            path = _safe_path(root, relative)
            expected_size = int(entry["byteLength"])
            expected_digest = str(entry["sha256"])
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(f"inventory entry {index}: {exc}")
            continue
        if relative in listed:
            errors.append(f"inventory contains duplicate path {relative}")
        listed.add(relative)
        if not path.is_file():
            errors.append(f"inventory path does not exist: {relative}")
            continue
        if path.is_symlink():
            errors.append(f"inventory path must not be a symlink: {relative}")
        if path.stat().st_size != expected_size:
            errors.append(f"inventory byteLength mismatch for {relative}")
        if _digest(path) != expected_digest:
            errors.append(f"inventory sha256 mismatch for {relative}")

    errors.extend(_portable_path_collision_errors(sorted(listed), "inventory"))

    canonical: set[str] = set()
    portable_paths: list[str] = []
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if relative.parts[0] == "sync":
            continue
        relative_text = relative.as_posix()
        portable_paths.append(relative_text)
        if path.is_symlink():
            errors.append(f"portable archive entry must not be a symlink: {relative_text}")
            continue
        if path.is_dir():
            continue
        if not path.is_file():
            errors.append(f"portable archive entry must be a regular file: {relative_text}")
            continue
        if path.stat().st_nlink > 1:
            errors.append(f"portable archive entry must not be a hard link: {relative_text}")
        if relative_text not in {"manifest.json", "inventory.json"}:
            canonical.add(relative_text)
    errors.extend(_portable_path_collision_errors(portable_paths, "portable archive"))
    if listed != canonical:
        missing = sorted(canonical - listed)
        extra = sorted(listed - canonical)
        if missing:
            errors.append(f"inventory misses canonical paths: {', '.join(missing)}")
        if extra:
            errors.append(f"inventory lists non-canonical paths: {', '.join(extra)}")
    return errors


def _validate_commit(
    commit: dict[str, Any],
    session: dict[str, Any],
    records: list[dict[str, Any]],
    artifacts: list[dict[str, Any]],
) -> list[str]:
    errors: list[str] = []
    commit_id = commit.get("commitId")
    capture_id = session.get("captureId")
    capture_records = [item for item in records if item.get("captureId") == capture_id]
    capture_artifacts = [item for item in artifacts if item.get("captureId") == capture_id]

    if commit.get("captureId") != capture_id:
        errors.append(f"commit {commit_id} has the wrong captureId")
    if commit.get("endedAt") != session.get("endedAt"):
        errors.append(f"commit {commit_id} endedAt differs from its session")
    if commit.get("supersedesCommitId") == commit_id:
        errors.append(f"commit {commit_id} must not supersede itself")

    summaries = commit.get("streamSummaries", [])
    summary_ids = [item.get("streamId") for item in summaries]
    if len(summary_ids) != len(set(summary_ids)):
        errors.append(f"commit {commit_id} has duplicate stream summaries")
    if set(summary_ids) != set(session.get("streamIds", [])):
        errors.append(f"commit {commit_id} summaries must cover exactly the session streamIds")

    gaps_by_stream: dict[str, list[dict[str, Any]]] = {}
    for gap in commit.get("gaps", []):
        gaps_by_stream.setdefault(str(gap.get("streamId")), []).append(gap)
    unknown_gap_streams = set(gaps_by_stream) - set(summary_ids)
    if unknown_gap_streams:
        errors.append(f"commit {commit_id} has gaps for unknown streams {sorted(unknown_gap_streams)}")

    for summary in summaries:
        stream_id = summary.get("streamId")
        stream_records = sorted(
            (item for item in capture_records if item.get("streamId") == stream_id),
            key=lambda item: item.get("streamSequence", -1),
        )
        sequences = [item.get("streamSequence") for item in stream_records]
        if not sequences:
            errors.append(f"commit {commit_id} summary {stream_id} has no observations")
            continue
        if summary.get("observationCount") != len(sequences):
            errors.append(f"commit {commit_id} summary {stream_id} observationCount differs")

        first, last = summary.get("firstSequence"), summary.get("lastSequence")
        if not isinstance(first, int) or not isinstance(last, int) or first > last:
            errors.append(f"commit {commit_id} summary {stream_id} has an invalid range")
            continue
        if sequences[0] < first or sequences[-1] > last:
            errors.append(
                f"commit {commit_id} observations for {stream_id} escape the committed range"
            )

        coverage: list[tuple[int, int, str]] = [
            (sequence, sequence, "observation") for sequence in sequences
        ]
        for gap in gaps_by_stream.get(str(stream_id), []):
            gap_first, gap_last = gap.get("firstSequence"), gap.get("lastSequence")
            if not isinstance(gap_first, int) or not isinstance(gap_last, int) or gap_first > gap_last:
                errors.append(f"commit {commit_id} has an invalid gap interval for {stream_id}")
                continue
            coverage.append((gap_first, gap_last, "gap"))

        cursor = first
        coverage_error = False
        for interval_first, interval_last, _kind in sorted(coverage):
            if interval_first != cursor:
                coverage_error = True
                break
            cursor = interval_last + 1
        if cursor != last + 1:
            coverage_error = True
        if coverage_error:
            errors.append(
                f"commit {commit_id} observations and gaps for {stream_id} "
                "do not exactly partition the committed range"
            )

    ordered_lines = [
        f"{item['streamId']}:{item['streamSequence']}:{item['observationId']}:{_jcs_digest(item)}"
        for item in sorted(
            capture_records, key=lambda item: (item.get("streamId", ""), item.get("streamSequence", -1))
        )
    ]
    if commit.get("orderedObservationDigest") != _text_digest(ordered_lines):
        errors.append(f"commit {commit_id} orderedObservationDigest differs")

    artifact_lines = [
        f"{item['artifactId']}:{item['content']['sha256']}"
        for item in sorted(capture_artifacts, key=lambda item: item.get("artifactId", ""))
    ]
    if commit.get("artifactCount") != len(capture_artifacts):
        errors.append(f"commit {commit_id} artifactCount differs")
    if commit.get("artifactSetDigest") != _text_digest(artifact_lines):
        errors.append(f"commit {commit_id} artifactSetDigest differs")
    return errors


def _validate_fixture(
    root: Path,
    schemas: dict[str, dict[str, Any]],
    schemas_by_id: dict[str, dict[str, Any]],
    registry: Registry,
) -> tuple[list[str], dict[str, Any] | None, dict[str, dict[str, Any]]]:
    errors: list[str] = []
    exported_ids: dict[str, dict[str, Any]] = {}
    try:
        manifest = _load_json(root / "manifest.json")
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return [f"manifest: {exc}"], None, exported_ids
    errors.extend(_schema_errors(manifest, "archive-manifest.schema.json", schemas, registry))
    if errors:
        return errors, manifest, exported_ids

    if manifest.get("supersedesArchiveId") == manifest["archiveId"]:
        errors.append("supersedesArchiveId must not self-reference archiveId")
    errors.extend(_validate_inventory(root, manifest, schemas, registry))

    actor_ids = [actor["actorId"] for actor in manifest["actors"]]
    source_ids = [source["sourceId"] for source in manifest["sources"]]
    if len(actor_ids) != len(set(actor_ids)):
        errors.append("actorId values must be unique")
    if len(source_ids) != len(set(source_ids)):
        errors.append("sourceId values must be unique")
    actors, sources = set(actor_ids), set(source_ids)
    actors_by_id = {actor["actorId"]: actor for actor in manifest["actors"]}
    sources_by_id = {source["sourceId"]: source for source in manifest["sources"]}
    for actor in manifest["actors"]:
        if actor.get("identityStatus") == "unknown" and (
            "displayName" in actor or "externalIdentities" in actor
        ):
            errors.append(
                f"unknown actor {actor['actorId']} must not inherit display or external identity metadata"
            )
        unknown = _provenance_sources(actor) - sources
        if unknown:
            errors.append(f"actor {actor['actorId']} references unknown sources {sorted(unknown)}")
    for source in manifest["sources"]:
        if source.get("actorId") and source["actorId"] not in actors:
            errors.append(f"source {source['sourceId']} references unknown actor")
        unknown = _provenance_sources(source) - sources
        if unknown:
            errors.append(f"source {source['sourceId']} references unknown sources {sorted(unknown)}")

    sessions: list[dict[str, Any]] = []
    labels: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    artifacts: list[dict[str, Any]] = []
    assertions: list[dict[str, Any]] = []
    session_paths_by_capture: dict[str, Path] = {}
    for session_ref in manifest["sessions"]:
        capture_id = session_ref["captureId"]
        try:
            session_path = _safe_path(root, session_ref["path"])
            session = _load_json(session_path)
            base = session_path.parent
            current_labels = _load_ndjson(base / "labels.ndjson")
            current_records = _load_ndjson(base / "records.ndjson")
            current_artifacts = _load_ndjson(base / "artifacts.ndjson")
            current_assertions = _load_ndjson(base / "assertions.ndjson")
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"capture {capture_id}: {exc}")
            continue
        errors.extend(_schema_errors(session, "archive-session.schema.json", schemas, registry))
        for value in current_labels:
            errors.extend(_schema_errors(value, "archive-label.schema.json", schemas, registry))
        for value in current_records:
            errors.extend(_schema_errors(value, "archive-record.schema.json", schemas, registry))
        for value in current_artifacts:
            errors.extend(_schema_errors(value, "archive-artifact.schema.json", schemas, registry))
        for value in current_assertions:
            errors.extend(_schema_errors(value, "archive-assertion.schema.json", schemas, registry))
        for kind, values in (
            ("label", current_labels),
            ("observation", current_records),
            ("artifact", current_artifacts),
        ):
            for value in values:
                if value.get("captureId") != capture_id:
                    errors.append(
                        f"{kind} {value.get(kind + 'Id', '<unknown>')} is stored under the wrong capture"
                    )
        if session.get("captureId") != capture_id:
            errors.append(f"session ref/path identity mismatch for {capture_id}")
        if session_ref.get("legacySessionId") != session.get("legacySessionId"):
            errors.append(f"legacy session identity mismatch for {capture_id}")
        if session.get("archiveId") != manifest["archiveId"]:
            errors.append(f"capture {capture_id} has the wrong archiveId")
        if manifest.get("state") == "finalized" and session.get("status") == "open":
            errors.append(f"finalized archive contains open capture {capture_id}")
        sessions.append(session)
        session_paths_by_capture[capture_id] = session_path
        labels.extend(current_labels)
        records.extend(current_records)
        artifacts.extend(current_artifacts)
        assertions.extend(current_assertions)

    delivery_path = root / "sync" / "delivery.ndjson"
    try:
        delivery = _load_ndjson(delivery_path)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        errors.append(f"delivery: {exc}")
        delivery = []
    for value in delivery:
        errors.extend(_schema_errors(value, "delivery-state.schema.json", schemas, registry))

    capture_ids = [str(item.get("captureId")) for item in sessions]
    observation_ids = [str(item.get("observationId")) for item in records]
    label_ids = [str(item.get("labelId")) for item in labels]
    artifact_ids = [str(item.get("artifactId")) for item in artifacts]
    assertion_ids = [str(item.get("assertionId")) for item in assertions]
    stream_ids = {str(stream_id) for item in sessions for stream_id in item.get("streamIds", [])}
    for name, values, count in (
        ("capture", capture_ids, len(sessions)),
        ("observation", observation_ids, len(records)),
        ("label", label_ids, len(labels)),
        ("artifact", artifact_ids, len(artifacts)),
        ("assertion", assertion_ids, len(assertions)),
    ):
        if len(set(values)) != count:
            errors.append(f"{name} IDs must be unique")

    ids: dict[str, set[str]] = {
        "archives": {manifest["archiveId"]},
        "captures": set(capture_ids),
        "commits": set(),
        "actors": actors,
        "sources": sources,
        "labels": set(label_ids),
        "observations": set(observation_ids),
        "artifacts": set(artifact_ids),
        "assertions": set(assertion_ids),
    }

    session_by_capture = {item["captureId"]: item for item in sessions if "captureId" in item}
    for session in sessions:
        capture_id = session.get("captureId")
        if session.get("recorderActorId") not in actors:
            errors.append(f"capture {capture_id} has unknown recorder actor")
        unknown = set(session.get("sourceIds", [])) - sources
        if unknown:
            errors.append(f"capture {capture_id} has unknown sources {sorted(unknown)}")

    contracts: dict[tuple[str, str], dict[str, Any]] = {}
    for contract in manifest["contracts"]:
        key = (contract["recordType"], contract["schemaId"])
        if key in contracts:
            errors.append(f"duplicate manifest contract {key}")
        contracts[key] = contract
        _, contract_error = _resolve_payload_contract(contract, schemas_by_id)
        if contract_error:
            errors.append(f"manifest declares {contract_error}")

    records_by_id = {item["observationId"]: item for item in records if "observationId" in item}
    labels_by_id = {item["labelId"]: item for item in labels if "labelId" in item}
    artifacts_by_id = {item["artifactId"]: item for item in artifacts if "artifactId" in item}
    sequences_by_stream: dict[str, list[int]] = {}
    forbidden_raw = {
        "caseId",
        "processInstanceId",
        "handoff",
        "intersection",
        "causedBy",
        "causes",
        "causalParentId",
        "causedByObservationId",
    }
    for record in records:
        observation_id = record.get("observationId")
        capture_id = record.get("captureId")
        stream_id = record.get("streamId")
        sequence = record.get("streamSequence")
        payload = record.get("payload", {})
        session = session_by_capture.get(str(capture_id))
        if record.get("originId") != manifest["originId"]:
            errors.append(f"observation {observation_id} has the wrong originId")
        if session is None:
            errors.append(f"observation {observation_id} references unknown capture")
        elif stream_id not in session.get("streamIds", []):
            errors.append(f"observation {observation_id} references undeclared stream")
        if isinstance(sequence, int):
            sequences_by_stream.setdefault(str(stream_id), []).append(sequence)

        contract_key = (str(record.get("recordType")), str(record.get("payloadSchema")))
        contract = contracts.get(contract_key)
        if contract is None:
            errors.append(f"observation {observation_id} has no matching manifest contract")
        else:
            payload_schema, contract_error = _resolve_payload_contract(contract, schemas_by_id)
            if contract_error:
                errors.append(f"observation {observation_id} uses {contract_error}")
            else:
                assert payload_schema is not None
                errors.extend(
                    _validation_errors(payload, payload_schema, f"payload {observation_id}", registry)
                )

        legacy = record.get("legacyCorrelation")
        if isinstance(legacy, dict):
            if legacy.get("eventId") != payload.get("eventId"):
                errors.append(f"observation {observation_id} legacy eventId differs from payload")
            if legacy.get("sessionId") != payload.get("sessionId"):
                errors.append(f"observation {observation_id} legacy sessionId differs from payload")
            if legacy.get("sequence") != payload.get("sequence"):
                errors.append(f"observation {observation_id} legacy sequence differs from payload")
            if session and legacy.get("sessionId") != session.get("legacySessionId"):
                errors.append(f"observation {observation_id} has the wrong legacy session")

        unknown_sources = {
            ref["sourceId"] for ref in record.get("sourceRefs", []) if ref["sourceId"] not in sources
        } | (_provenance_sources(record) - sources)
        if unknown_sources:
            errors.append(f"observation {observation_id} has unknown sources {sorted(unknown_sources)}")
        if session is not None:
            undeclared_sources = {
                ref["sourceId"] for ref in record.get("sourceRefs", [])
            } - set(session.get("sourceIds", []))
            if undeclared_sources:
                errors.append(
                    f"observation {observation_id} uses sources not declared by its capture "
                    f"{sorted(undeclared_sources)}"
                )
        unknown_actors = {
            ref["actorId"] for ref in record.get("actorRefs", []) if ref["actorId"] not in actors
        }
        if unknown_actors:
            errors.append(f"observation {observation_id} has unknown actors {sorted(unknown_actors)}")

        monotonic = record.get("monotonicTime")
        if isinstance(monotonic, dict):
            source_clocks = [
                sources_by_id[ref["sourceId"]].get("clock", {})
                for ref in record.get("sourceRefs", [])
                if ref.get("sourceId") in sources_by_id
            ]
            if not any(
                clock.get("monotonicClock") == monotonic.get("clockId")
                and clock.get("clockDomainId") == monotonic.get("clockDomainId")
                and clock.get("bootId") == monotonic.get("bootId")
                for clock in source_clocks
            ):
                errors.append(f"observation {observation_id} has an undeclared clock/boot domain")

        if record.get("provenance", {}).get("factClass") in {"derived", "corrected"}:
            errors.append(f"raw observation {observation_id} must not be derived/corrected")
        found = _contains_key(payload, forbidden_raw)
        if found:
            errors.append(f"raw observation {observation_id} contains derived process key {found}")
        errors.extend(
            _media_observation_errors(record, actors_by_id, sources_by_id, artifacts_by_id)
        )
        errors.extend(
            _meeting_control_observation_errors(
                record,
                session,
                actors_by_id,
                sources_by_id,
            )
        )
    for stream_id, sequences in sequences_by_stream.items():
        if sequences != sorted(set(sequences)):
            errors.append(f"streamSequence must be unique and increasing for {stream_id}")
    errors.extend(_meeting_control_timeline_errors(records))

    for label in labels:
        label_id = label["labelId"]
        capture_id = label.get("captureId")
        if capture_id not in ids["captures"]:
            errors.append(f"label {label_id} references unknown capture")
        if label["declaration"]["declaredByActorId"] not in actors:
            errors.append(f"label {label_id} references unknown declaring actor")
        interval = label["interval"]
        start = records_by_id.get(interval["startObservationId"])
        end = records_by_id.get(interval.get("endObservationId"))
        if (
            not start
            or start.get("captureId") != capture_id
            or start.get("streamSequence") != interval["startStreamSequence"]
        ):
            errors.append(f"label {label_id} has invalid start boundary")
        if interval.get("endObservationId") and (
            not end
            or end.get("captureId") != capture_id
            or end.get("streamSequence") != interval.get("endStreamSequence")
        ):
            errors.append(f"label {label_id} has invalid end boundary")
        if interval.get("endStreamSequence", interval["startStreamSequence"]) < interval[
            "startStreamSequence"
        ]:
            errors.append(f"label {label_id} ends before it starts")
        unknown_sources = _provenance_sources(label) - sources
        if unknown_sources:
            errors.append(f"label {label_id} has unknown provenance sources {sorted(unknown_sources)}")
        for artifact_id in label.get("narrationArtifactRefs", []):
            artifact = artifacts_by_id.get(artifact_id)
            if artifact is None:
                errors.append(f"label {label_id} references unknown narration artifact {artifact_id}")
            elif artifact.get("captureId") != capture_id:
                errors.append(f"label {label_id} references narration from another capture")
    errors.extend(_label_lineage_errors(labels, records_by_id))

    for record in records:
        observation_id = record["observationId"]
        for label_id in record.get("labelRefs", []):
            label = labels_by_id.get(label_id)
            if label is None:
                errors.append(f"observation {observation_id} references unknown label {label_id}")
            elif label.get("captureId") != record.get("captureId"):
                errors.append(f"observation {observation_id} references a label from another capture")
        for ref in record.get("artifactRefs", []):
            artifact = artifacts_by_id.get(ref["artifactId"])
            if artifact is None:
                errors.append(
                    f"observation {observation_id} references unknown artifact {ref['artifactId']}"
                )
            elif artifact.get("captureId") != record.get("captureId"):
                errors.append(
                    f"observation {observation_id} references an artifact from another capture"
                )

    for artifact in artifacts:
        artifact_id = artifact["artifactId"]
        if artifact.get("captureId") not in ids["captures"]:
            errors.append(f"artifact {artifact_id} references unknown capture")
        for ref in artifact.get("sourceRefs", []):
            if ref["sourceId"] not in sources:
                errors.append(f"artifact {artifact_id} references unknown source")
            session = session_by_capture.get(str(artifact.get("captureId")))
            if session is not None and ref["sourceId"] not in session.get("sourceIds", []):
                errors.append(f"artifact {artifact_id} uses a source not declared by its capture")
        for ref in artifact.get("actorRefs", []):
            if ref["actorId"] not in actors:
                errors.append(f"artifact {artifact_id} references unknown actor")
        for label_id in artifact.get("labelRefs", []):
            label = labels_by_id.get(label_id)
            if label is None:
                errors.append(f"artifact {artifact_id} references unknown label")
            elif label.get("captureId") != artifact.get("captureId"):
                errors.append(f"artifact {artifact_id} references a label from another capture")
        for observation_id in artifact.get("observationRefs", []):
            observation = records_by_id.get(observation_id)
            if observation is None:
                errors.append(f"artifact {artifact_id} references unknown observation")
            elif observation.get("captureId") != artifact.get("captureId"):
                errors.append(f"artifact {artifact_id} references an observation from another capture")
        unknown_sources = _provenance_sources(artifact) - sources
        if unknown_sources:
            errors.append(
                f"artifact {artifact_id} has unknown provenance sources {sorted(unknown_sources)}"
            )
        content = artifact["content"]
        try:
            blob = _safe_path(root, content["path"])
        except ValueError as exc:
            errors.append(f"artifact {artifact_id}: {exc}")
            continue
        if not blob.is_file() or blob.stat().st_size != content["byteLength"]:
            errors.append(f"artifact {artifact_id} content missing or byteLength differs")
        elif _digest(blob) != content["sha256"]:
            errors.append(f"artifact {artifact_id} content sha256 differs")
        if blob.name != content["sha256"]:
            errors.append(f"artifact {artifact_id} blob filename must equal its sha256")
        if artifact["origin"] == "derived":
            for ref in artifact["derivation"]["inputRefs"]:
                if not _target_exists(ref["kind"], ref["id"], ids):
                    errors.append(f"derived artifact {artifact_id} has unresolved input ref {ref}")
        elif artifact.get("derivation") is not None:
            errors.append(f"non-derived artifact {artifact_id} must not have derivation")

    commit_refs = manifest.get("captureCommits", [])
    refs_by_capture = {ref["captureId"]: ref for ref in commit_refs}
    if len(refs_by_capture) != len(commit_refs):
        errors.append("manifest captureCommit refs must have unique captureId values")
    if manifest.get("state") == "finalized" and set(refs_by_capture) != ids["captures"]:
        errors.append("a finalized manifest must commit every capture exactly once")
    commits: list[dict[str, Any]] = []
    for capture_id, ref in refs_by_capture.items():
        session = session_by_capture.get(capture_id)
        if session is None:
            errors.append(f"commit ref points to unknown capture {capture_id}")
            continue
        if session.get("captureCommit") != ref:
            errors.append(f"capture {capture_id} and manifest must reference the same commit")
        try:
            commit_path = _safe_path(root, ref["path"])
            commit = _load_json(commit_path)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(f"commit {ref['commitId']}: {exc}")
            continue
        if commit_path != session_paths_by_capture[capture_id].parent / "commit.json":
            errors.append(f"commit {ref['commitId']} is not colocated with its session")
        errors.extend(
            _schema_errors(commit, "archive-capture-commit.schema.json", schemas, registry)
        )
        if _jcs_digest(commit) != ref["digest"]:
            errors.append(f"commit {ref['commitId']} digest differs")
        if commit.get("commitId") != ref["commitId"] or commit.get("captureId") != capture_id:
            errors.append(f"commit ref identity mismatch for {ref['commitId']}")
        commits.append(commit)
        ids["commits"].add(str(commit.get("commitId")))
        errors.extend(_validate_commit(commit, session, records, artifacts))

    for assertion in assertions:
        target = assertion["target"]
        if not _target_exists(target["kind"], target["id"], ids):
            errors.append(f"assertion {assertion['assertionId']} has unresolved target")
        if assertion["authoredByActorId"] not in actors:
            errors.append(f"assertion {assertion['assertionId']} has unknown author")
        if assertion.get("supersedes") and assertion["supersedes"] not in ids["assertions"]:
            errors.append(f"assertion {assertion['assertionId']} supersedes an unknown assertion")
        unknown_sources = _provenance_sources(assertion) - sources
        if unknown_sources:
            errors.append(
                f"assertion {assertion['assertionId']} has unknown provenance sources "
                f"{sorted(unknown_sources)}"
            )

    for item in delivery:
        for ref in item["subjectRefs"]:
            if not _target_exists(ref["kind"], ref["id"], ids):
                errors.append(f"delivery {item['deliveryId']} has unresolved subject ref {ref}")

    canonical_values: list[Any] = [
        manifest,
        *sessions,
        *commits,
        *labels,
        *records,
        *artifacts,
        *assertions,
    ]
    forbidden_credentials = {
        "token",
        "accessToken",
        "refreshToken",
        "authorization",
        "streamEndpoint",
        "signedUrl",
        "uploadUrl",
    }
    for value in canonical_values:
        found = _contains_key(value, forbidden_credentials)
        if found:
            errors.append(f"canonical archive contains forbidden transport credential key {found}")
            break

    commit_by_capture = {
        str(commit.get("captureId")): commit for commit in commits if commit.get("captureId")
    }
    exported_ids = {
        "observationId": {
            record["observationId"]: _jcs_digest(record)
            for record in records
            if "observationId" in record
        },
        "commitId": {
            commit["commitId"]: _jcs_digest(commit) for commit in commits if "commitId" in commit
        },
        "streamId": {
            str(stream_id): session["captureId"]
            for session in sessions
            for stream_id in session.get("streamIds", [])
        },
        "captureId": {
            capture_id: {
                "archiveId": manifest["archiveId"],
                "archiveRevision": manifest["revision"],
                "supersedesArchiveId": manifest.get("supersedesArchiveId"),
                "commitId": commit_by_capture.get(capture_id, {}).get("commitId"),
                "commitRevision": commit_by_capture.get(capture_id, {}).get("revision"),
                "commitDigest": refs_by_capture.get(capture_id, {}).get("digest"),
            }
            for capture_id in ids["captures"]
        },
    }
    return errors, manifest, exported_ids


def _capture_revision_errors(capture_id: str, claims: list[dict[str, Any]]) -> list[str]:
    committed = [
        claim
        for claim in claims
        if isinstance(claim.get("commitDigest"), str)
        and isinstance(claim.get("commitRevision"), int)
    ]
    if len({claim["commitDigest"] for claim in committed}) <= 1:
        return []

    # Exact archive re-imports can appear more than once in conformance inputs; compare one claim
    # per immutable archive identity/content pair.
    unique: dict[tuple[str, str], dict[str, Any]] = {}
    for claim in committed:
        unique[(claim["archiveId"], claim["commitDigest"])] = claim
    committed = list(unique.values())
    minimum_revision = min(claim["commitRevision"] for claim in committed)
    base_digests = {
        claim["commitDigest"]
        for claim in committed
        if claim["commitRevision"] == minimum_revision
    }
    if len(base_digests) != 1:
        return [
            f"captureId {capture_id} has conflicting commit digests at revision {minimum_revision}"
        ]
    base_digest = next(iter(base_digests))
    by_archive = {claim["archiveId"]: claim for claim in committed}
    errors: list[str] = []
    for claim in committed:
        predecessor_id = claim.get("supersedesArchiveId")
        predecessor = by_archive.get(predecessor_id)
        changed_from_base = claim["commitDigest"] != base_digest
        changed_from_predecessor = (
            predecessor is not None
            and claim["commitDigest"] != predecessor.get("commitDigest")
        )
        if not changed_from_base and not changed_from_predecessor:
            continue
        if predecessor is None:
            errors.append(
                f"captureId {capture_id} changes committed content in archive "
                f"{claim['archiveId']} without superseding an archive that contains the capture"
            )
            continue
        if claim["commitRevision"] <= predecessor["commitRevision"]:
            errors.append(
                f"captureId {capture_id} commit revision must increase over superseded archive "
                f"{predecessor_id}"
            )
    return errors


def _negative_mutation_self_check(
    schemas: dict[str, dict[str, Any]],
    schemas_by_id: dict[str, dict[str, Any]],
    registry: Registry,
) -> None:
    """Prove that critical invalid mutations fail for the intended invariant."""

    fixture = FIXTURES_DIR / "01-minimal-desktop"
    manifest = _load_json(fixture / "manifest.json")
    session_path = next(fixture.glob("sessions/*/session.json"))
    session = _load_json(session_path)
    commit = _load_json(session_path.parent / "commit.json")
    records = _load_ndjson(session_path.parent / "records.ndjson")

    record_without_origin = deepcopy(records[0])
    record_without_origin.pop("originId")
    if not _schema_errors(
        record_without_origin, "archive-record.schema.json", schemas, registry
    ):
        raise ValueError("negative self-check: record without originId was accepted")

    known_contract = deepcopy(manifest["contracts"][0])
    if _resolve_payload_contract(known_contract, schemas_by_id)[0] is None:
        raise ValueError("negative self-check: installed payload contract was rejected")
    wrong_version = deepcopy(known_contract)
    wrong_version["schemaVersion"] += 1
    if _resolve_payload_contract(wrong_version, schemas_by_id)[1] is None:
        raise ValueError("negative self-check: wrong payload schemaVersion was accepted")
    wrong_schema = deepcopy(known_contract)
    wrong_schema["schemaId"] = "https://jasnost.dev/archive/schema/archive-common.schema.json"
    if _resolve_payload_contract(wrong_schema, schemas_by_id)[1] is None:
        raise ValueError("negative self-check: non-payload local schema was accepted")

    changed_record = deepcopy(records)
    changed_record[0]["capturedAt"] = "2026-07-22T08:00:00.001Z"
    if not any(
        "orderedObservationDigest" in error
        for error in _validate_commit(commit, session, changed_record, [])
    ):
        raise ValueError("negative self-check: mutated observation was not bound by commit JCS")

    changed_manifest = deepcopy(manifest)
    changed_manifest["producer"]["version"] = "tampered"
    if not _content_digest_errors(changed_manifest):
        raise ValueError("negative self-check: mutated manifest was not bound by contentDigest")
    live_manifest = deepcopy(manifest)
    live_manifest["state"] = "live"
    live_manifest.pop("contentDigest")
    if _content_digest_errors(live_manifest):
        raise ValueError("negative self-check: live manifest without contentDigest was rejected")

    nested_inventory = deepcopy(manifest)
    nested_inventory["inventory"]["path"] = "nested/inventory.json"
    if not _schema_errors(
        nested_inventory, "archive-manifest.schema.json", schemas, registry
    ):
        raise ValueError("negative self-check: non-root inventory path was accepted")
    if not _portable_path_collision_errors(["sessions/A/data", "sessions/a/data"], "test"):
        raise ValueError("negative self-check: case-colliding paths were accepted")

    identity_digest = _jcs_digest(records[0])
    if _digested_identity_conflicts(identity_digest, identity_digest):
        raise ValueError("negative self-check: idempotent identity replay was rejected")
    if not _digested_identity_conflicts(identity_digest, "0" * 64):
        raise ValueError("negative self-check: conflicting identity digest was accepted")

    base_claim = {
        "archiveId": "base",
        "commitRevision": 1,
        "commitDigest": "a" * 64,
        "supersedesArchiveId": None,
    }
    conflicting_claim = {
        "archiveId": "changed",
        "commitRevision": 2,
        "commitDigest": "b" * 64,
        "supersedesArchiveId": None,
    }
    if not _capture_revision_errors("capture", [base_claim, conflicting_claim]):
        raise ValueError("negative self-check: unversioned capture conflict was accepted")
    conflicting_claim["supersedesArchiveId"] = "base"
    if _capture_revision_errors("capture", [base_claim, conflicting_claim]):
        raise ValueError("negative self-check: valid increasing capture revision was rejected")

    unknown_actor = {
        "actorId": "actor-11111111-1111-7111-8111-111111111111",
        "kind": "human",
        "identityStatus": "unknown",
        "identityReason": "participant metadata unavailable",
        "displayName": "Meeting organizer",
        "provenance": {"factClass": "observed", "sources": []},
    }
    actor_probe_schema = {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "$ref": "https://jasnost.dev/archive/schema/archive-common.schema.json#/$defs/actor",
    }
    if not _validation_errors(unknown_actor, actor_probe_schema, "actor", registry):
        raise ValueError("negative self-check: guessed identity on an unknown actor was accepted")

    meeting_session = next(
        (FIXTURES_DIR / "04-meeting-screen-share").glob("sessions/*/session.json")
    )
    meeting_records = _load_ndjson(meeting_session.parent / "records.ndjson")
    rebound_presence = deepcopy(meeting_records)
    leave = next(
        record
        for record in rebound_presence
        if record.get("payload", {}).get("eventType") == "participant_left"
    )
    leave["payload"]["participantInstanceId"] = "different-presence"
    if not _meeting_control_timeline_errors(rebound_presence):
        raise ValueError("negative self-check: unpaired participant leave was accepted")

    lineage_records = {
        "start-a": {"streamId": "stream-a", "streamSequence": 1},
        "start-b": {"streamId": "stream-a", "streamSequence": 2},
        "start-c": {"streamId": "stream-a", "streamSequence": 3},
    }
    lineage_baseline = {
        "labelId": "label-a",
        "captureId": "capture-a",
        "declaration": {"text": "Issue invoice"},
        "processBinding": {"areaId": "finance", "processId": "issue-invoice"},
        "interval": {"startObservationId": "start-a"},
        "lineage": {"baselineLabelId": "label-a"},
    }
    lineage_successor = {
        "labelId": "label-b",
        "captureId": "capture-a",
        "declaration": {"text": "Issue invoice"},
        "processBinding": {"areaId": "finance", "processId": "issue-invoice"},
        "interval": {"startObservationId": "start-b"},
        "lineage": {
            "baselineLabelId": "label-a",
            "resumesLabelId": "label-a",
        },
    }
    if _label_lineage_errors(
        [lineage_baseline, lineage_successor],
        lineage_records,
    ):
        raise ValueError("negative self-check: valid label lineage was rejected")
    lineage_branch = deepcopy(lineage_successor)
    lineage_branch["labelId"] = "label-c"
    lineage_branch["interval"]["startObservationId"] = "start-c"
    if not _label_lineage_errors(
        [lineage_baseline, lineage_successor, lineage_branch],
        lineage_records,
    ):
        raise ValueError("negative self-check: branched label lineage was accepted")
    reverse_records = deepcopy(lineage_records)
    reverse_records["start-a"]["streamSequence"] = 4
    if not _label_lineage_errors(
        [lineage_baseline, lineage_successor],
        reverse_records,
    ):
        raise ValueError("negative self-check: reverse label lineage was accepted")


def main() -> int:
    try:
        _jcs_self_check()
        schemas, schemas_by_id, registry = _schemas()
        _negative_mutation_self_check(schemas, schemas_by_id, registry)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL  schemas: {exc}", file=sys.stderr)
        return 1
    fixtures = sorted(path for path in FIXTURES_DIR.iterdir() if path.is_dir())
    if not fixtures:
        print("FAIL  no archive fixtures found", file=sys.stderr)
        return 1

    failures = 0
    manifests: dict[str, tuple[str | None, int, str | None]] = {}
    digested_identities: dict[str, dict[str, tuple[str, str]]] = {
        "observationId": {},
        "commitId": {},
    }
    stream_identities: dict[str, tuple[str, str]] = {}
    capture_claims: dict[str, list[dict[str, Any]]] = {}
    for fixture in fixtures:
        errors, manifest, exported_ids = _validate_fixture(
            fixture, schemas, schemas_by_id, registry
        )
        if errors:
            failures += 1
            print(f"FAIL  {fixture.name}", file=sys.stderr)
            for error in errors:
                print(f"      {error}", file=sys.stderr)
            continue
        assert manifest is not None

        for kind in ("observationId", "commitId"):
            for identifier, identity_digest in exported_ids[kind].items():
                prior = digested_identities[kind].get(identifier)
                if _digested_identity_conflicts(prior[0] if prior else None, identity_digest):
                    errors.append(
                        f"{kind} {identifier} conflicts with fixture {prior[1]}: canonical digests differ"
                    )
        for stream_id, capture_id in exported_ids["streamId"].items():
            prior = stream_identities.get(stream_id)
            if prior is not None and prior[0] != capture_id:
                errors.append(
                    f"streamId {stream_id} is reused by capture {capture_id}; fixture {prior[1]} "
                    f"binds it to {prior[0]}"
                )

        archive_id = manifest["archiveId"]
        digest = manifest.get("contentDigest")
        previous = manifests.get(archive_id)
        if isinstance(digest, str) and _digested_identity_conflicts(
            previous[0] if previous else None, digest
        ):
            errors.append(f"archiveId {archive_id} has a conflicting contentDigest")
        if errors:
            failures += 1
            print(f"FAIL  {fixture.name}", file=sys.stderr)
            for error in errors:
                print(f"      {error}", file=sys.stderr)
            continue

        for kind in ("observationId", "commitId"):
            for identifier, identity_digest in exported_ids[kind].items():
                digested_identities[kind].setdefault(
                    identifier, (identity_digest, fixture.name)
                )
        for stream_id, capture_id in exported_ids["streamId"].items():
            stream_identities.setdefault(stream_id, (capture_id, fixture.name))
        for capture_id, claim in exported_ids["captureId"].items():
            capture_claims.setdefault(capture_id, []).append(claim)
        manifests.setdefault(
            archive_id,
            (digest, int(manifest["revision"]), manifest.get("supersedesArchiveId")),
        )
        print(f"ok    {fixture.name}")

    revisions = {archive_id: revision for archive_id, (_, revision, _) in manifests.items()}
    for archive_id, (_, revision, supersedes) in manifests.items():
        if supersedes in revisions and revision <= revisions[supersedes]:
            failures += 1
            print(
                f"FAIL  {archive_id}: revision must increase over superseded archive {supersedes}",
                file=sys.stderr,
            )
    for capture_id, claims in capture_claims.items():
        for error in _capture_revision_errors(capture_id, claims):
            failures += 1
            print(f"FAIL  {error}", file=sys.stderr)
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
