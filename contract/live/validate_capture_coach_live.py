#!/usr/bin/env python3
"""Validate strict-JCS Capture Coach advisory documents and replay semantics."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import sys
from copy import deepcopy
from datetime import datetime
from pathlib import Path
from typing import Any, Literal

from jsonschema import Draft202012Validator, FormatChecker
from referencing import Registry, Resource

LIVE_DIR = Path(__file__).resolve().parent
CONTRACT_DIR = LIVE_DIR.parent
ARCHIVE_DIR = CONTRACT_DIR / "archive"
FIXTURE_DIR = LIVE_DIR / "coach" / "fixtures"
MAXIMUM_MESSAGE_BYTES = 1_048_576
MAXIMUM_TRANSCRIPT_TEXT_BYTES = 8_192
MAXIMUM_AUDIO_BYTES = 262_144
MAXIMUM_PREVIEW_BYTES = 393_216

sys.path.insert(0, str(ARCHIVE_DIR))
from validate_archives import _jcs, _jcs_digest, _jcs_self_check  # noqa: E402

WatermarkRelation = Literal["equal", "dominates", "dominated", "incomparable"]


def _schemas() -> tuple[
    dict[str, Any], dict[str, Any], Draft202012Validator, Draft202012Validator
]:
    protocol = json.loads(
        (LIVE_DIR / "schema" / "capture-coach-live.schema.json").read_text(
            encoding="utf-8"
        )
    )
    fixture = json.loads(
        (LIVE_DIR / "schema" / "capture-coach-live-fixture.schema.json").read_text(
            encoding="utf-8"
        )
    )
    registry = Registry().with_resources(
        [
            (protocol["$id"], Resource.from_contents(protocol)),
            (fixture["$id"], Resource.from_contents(fixture)),
        ]
    )
    return (
        protocol,
        fixture,
        Draft202012Validator(
            protocol,
            registry=registry,
            format_checker=FormatChecker(),
        ),
        Draft202012Validator(
            fixture,
            registry=registry,
            format_checker=FormatChecker(),
        ),
    )


def _walk_integers(value: Any, field: str = "$") -> list[str]:
    errors: list[str] = []
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return errors
    if isinstance(value, float):
        return [f"{field}: floating-point numbers are forbidden in live Coach documents"]
    if isinstance(value, int):
        if abs(value) > 9_007_199_254_740_991:
            errors.append(f"{field}: integer is outside the I-JSON safe range")
        return errors
    if isinstance(value, list):
        for index, item in enumerate(value):
            errors.extend(_walk_integers(item, f"{field}/{index}"))
        return errors
    if isinstance(value, dict):
        for key, item in value.items():
            errors.extend(_walk_integers(item, f"{field}/{key}"))
    return errors


def _strict_document_errors(
    document: dict[str, Any],
    canonical_bytes: str,
    validator: Draft202012Validator,
    where: str,
) -> list[str]:
    errors = [
        f"{where}: {error.message}"
        for error in sorted(validator.iter_errors(document), key=lambda item: list(item.path))
    ]
    errors.extend(_walk_integers(document, where))
    try:
        expected_bytes = _jcs(document)
        material = {
            key: value for key, value in document.items() if key != "contentDigest"
        }
        expected_digest = _jcs_digest(material)
    except (TypeError, UnicodeError, ValueError) as exc:
        return [*errors, f"{where}: invalid JCS: {exc}"]
    if canonical_bytes != expected_bytes:
        errors.append(f"{where}: canonicalBytes is not the exact RFC 8785 document")
    if document.get("contentDigest") != expected_digest:
        errors.append(f"{where}: contentDigest does not bind JCS(document without contentDigest)")
    return errors


def _strict_response_errors(
    response: dict[str, Any],
    canonical_bytes: str,
    validator: Draft202012Validator,
    where: str,
) -> list[str]:
    errors = [
        f"{where}: {error.message}"
        for error in sorted(
            validator.iter_errors(response), key=lambda item: list(item.path)
        )
    ]
    errors.extend(_walk_integers(response, where))
    try:
        expected_bytes = _jcs(response)
    except (TypeError, UnicodeError, ValueError) as exc:
        return [*errors, f"{where}: invalid JCS: {exc}"]
    if canonical_bytes != expected_bytes:
        errors.append(f"{where}: responseCanonicalBytes is not exact RFC 8785")
    return errors


def _identity_vector_errors(
    watermark: dict[str, Any], where: str
) -> list[str]:
    errors: list[str] = []
    streams = watermark["streams"]
    stream_ids = [item["streamId"] for item in streams]
    if stream_ids != sorted(stream_ids):
        errors.append(f"{where}: streams must be ordered by streamId")
    if len(stream_ids) != len(set(stream_ids)):
        errors.append(f"{where}: streamId appears more than once")
    transcripts = watermark["transcripts"]
    transcript_ids = [item["transcriptId"] for item in transcripts]
    if transcript_ids != sorted(transcript_ids):
        errors.append(f"{where}: transcripts must be ordered by transcriptId")
    if len(transcript_ids) != len(set(transcript_ids)):
        errors.append(f"{where}: transcriptId appears more than once")
    return errors


def _coordinate_relation(previous: int, current: int) -> int:
    return 0 if current == previous else 1 if current > previous else -1


def _watermark_relation(
    current: dict[str, Any], previous: dict[str, Any]
) -> WatermarkRelation:
    if current["captureId"] != previous["captureId"]:
        return "incomparable"
    signs: set[int] = set()
    current_streams = {
        item["streamId"]: item["throughSequence"] for item in current["streams"]
    }
    previous_streams = {
        item["streamId"]: item["throughSequence"] for item in previous["streams"]
    }
    for identifier in set(current_streams) | set(previous_streams):
        if identifier not in current_streams:
            signs.add(-1)
        elif identifier not in previous_streams:
            signs.add(1)
        else:
            signs.add(
                _coordinate_relation(
                    previous_streams[identifier], current_streams[identifier]
                )
            )

    current_transcripts = {
        item["transcriptId"]: item for item in current["transcripts"]
    }
    previous_transcripts = {
        item["transcriptId"]: item for item in previous["transcripts"]
    }
    for identifier in set(current_transcripts) | set(previous_transcripts):
        if identifier not in current_transcripts:
            signs.add(-1)
            continue
        if identifier not in previous_transcripts:
            signs.add(1)
            continue
        now = current_transcripts[identifier]
        before = previous_transcripts[identifier]
        revision_sign = _coordinate_relation(before["revision"], now["revision"])
        through_sign = _coordinate_relation(before["throughMillis"], now["throughMillis"])
        signs.update((revision_sign, through_sign))
        if before["finalized"] and not now["finalized"]:
            signs.add(-1)
        elif now["finalized"] and not before["finalized"]:
            signs.add(1)
        if revision_sign == 0 and through_sign == 0:
            if (
                now["textDigest"] != before["textDigest"]
                or now.get("contentDigest") != before.get("contentDigest")
                or now["finalized"] != before["finalized"]
            ):
                return "incomparable"

    now_commit = current.get("captureCommit")
    before_commit = previous.get("captureCommit")
    if now_commit is None and before_commit is not None:
        signs.add(-1)
    elif now_commit is not None and before_commit is None:
        signs.add(1)
    elif now_commit != before_commit:
        return "incomparable"

    signs.discard(0)
    if not signs:
        return "equal"
    if signs == {1}:
        return "dominates"
    if signs == {-1}:
        return "dominated"
    return "incomparable"


def _decode_bounded_base64(
    value: str, declared_length: int, maximum: int, where: str
) -> tuple[bytes | None, list[str]]:
    try:
        padding = "=" * (-len(value) % 4)
        decoded = base64.b64decode(value + padding, validate=True)
    except (binascii.Error, ValueError) as exc:
        return None, [f"{where}: invalid base64: {exc}"]
    errors: list[str] = []
    if len(decoded) != declared_length:
        errors.append(f"{where}: byteLength does not match decoded bytes")
    if len(decoded) > maximum:
        errors.append(f"{where}: decoded bytes exceed the hard limit")
    return decoded, errors


def _message_semantic_errors(message: dict[str, Any], where: str) -> list[str]:
    errors = _identity_vector_errors(message["inputWatermark"], f"{where}/inputWatermark")
    if message["captureId"] != message["inputWatermark"]["captureId"]:
        errors.append(f"{where}: captureId differs from inputWatermark.captureId")
    encoded_size = len(_jcs(message).encode("utf-8"))
    if encoded_size > MAXIMUM_MESSAGE_BYTES:
        errors.append(f"{where}: message exceeds the one MiB hard limit")

    stream_watermarks = {
        item["streamId"]: item["throughSequence"]
        for item in message["inputWatermark"]["streams"]
    }
    transcript_watermarks = {
        item["transcriptId"]: item
        for item in message["inputWatermark"]["transcripts"]
    }
    kind_counts = {
        "canonicalObservation": 0,
        "transcriptSpan": 0,
        "audioChunk": 0,
    }
    preview_bytes = 0
    evidence_keys: set[tuple[Any, ...]] = set()
    for index, evidence in enumerate(message["evidence"]):
        kind = evidence["kind"]
        kind_counts[kind] += 1
        if kind == "transcriptSpan":
            key = (
                kind,
                evidence["transcriptId"],
                evidence["revision"],
                evidence["startMillis"],
                evidence["endMillis"],
                evidence["textDigest"],
            )
        else:
            key = (
                kind,
                str(evidence.get("observationId") or evidence.get("chunkId")),
            )
        if key in evidence_keys:
            errors.append(f"{where}/evidence/{index}: duplicate evidence identity")
        evidence_keys.add(key)
        if kind == "canonicalObservation":
            if stream_watermarks.get(evidence["streamId"], -1) < evidence["streamSequence"]:
                errors.append(
                    f"{where}/evidence/{index}: observation is beyond its stream watermark"
                )
            context = evidence["sanitizedContext"]
            inspected = " ".join(
                str(context.get(field, ""))
                for field in ("documentRef", "targetName", "payloadSummary")
            ).lower()
            if any(
                marker in inspected
                for marker in (
                    "authorization:",
                    "x-storageapi-token",
                    "password=",
                    "token=",
                )
            ):
                errors.append(
                    f"{where}/evidence/{index}: obvious credential material is not privacy-filtered"
                )
            preview = evidence.get("preview")
            if preview is not None:
                if (
                    context["maskedFields"]
                    and preview["privacy"]["status"] != "masked"
                ):
                    errors.append(
                        f"{where}/evidence/{index}/preview: masked AX context lacks pixel masking proof"
                    )
                decoded, preview_errors = _decode_bounded_base64(
                    preview["contentBase64"],
                    preview["byteLength"],
                    MAXIMUM_PREVIEW_BYTES,
                    f"{where}/evidence/{index}/preview",
                )
                errors.extend(preview_errors)
                if decoded is not None:
                    preview_bytes += len(decoded)
                    if hashlib.sha256(decoded).hexdigest() != preview["contentSha256"]:
                        errors.append(
                            f"{where}/evidence/{index}/preview: contentSha256 mismatch"
                        )
        elif kind == "transcriptSpan":
            if evidence["endMillis"] <= evidence["startMillis"]:
                errors.append(
                    f"{where}/evidence/{index}: transcript span must have positive duration"
                )
            if len(evidence["text"].encode("utf-8")) > MAXIMUM_TRANSCRIPT_TEXT_BYTES:
                errors.append(f"{where}/evidence/{index}: transcript text exceeds 8 KiB")
            if (
                hashlib.sha256(evidence["text"].encode("utf-8")).hexdigest()
                != evidence["textDigest"]
            ):
                errors.append(f"{where}/evidence/{index}: textDigest mismatch")
            watermark = transcript_watermarks.get(evidence["transcriptId"])
            if (
                watermark is None
                or watermark["revision"] != evidence["revision"]
                or watermark["throughMillis"] < evidence["endMillis"]
                or (evidence["finalized"] and not watermark["finalized"])
            ):
                errors.append(
                    f"{where}/evidence/{index}: transcript span is not closed by its watermark"
                )
        elif kind == "audioChunk":
            if evidence["endMillis"] <= evidence["startMillis"]:
                errors.append(
                    f"{where}/evidence/{index}: audio chunk must have positive duration"
                )
            if stream_watermarks.get(evidence["streamId"], -1) < evidence["streamSequence"]:
                errors.append(
                    f"{where}/evidence/{index}: audio chunk is beyond its stream watermark"
                )
            decoded, audio_errors = _decode_bounded_base64(
                evidence["contentBase64"],
                evidence["byteLength"],
                MAXIMUM_AUDIO_BYTES,
                f"{where}/evidence/{index}/audio",
            )
            errors.extend(audio_errors)
            if decoded is not None:
                if hashlib.sha256(decoded).hexdigest() != evidence["contentSha256"]:
                    errors.append(f"{where}/evidence/{index}: contentSha256 mismatch")
    if kind_counts["canonicalObservation"] > 16:
        errors.append(f"{where}: more than 16 canonical observations")
    if kind_counts["transcriptSpan"] > 8:
        errors.append(f"{where}: more than 8 transcript spans")
    if kind_counts["audioChunk"] > 1:
        errors.append(f"{where}: more than one audio chunk")
    if preview_bytes > MAXIMUM_PREVIEW_BYTES:
        errors.append(f"{where}: image previews exceed 384 KiB in aggregate")
    return errors


def validate_capture_coach_fixture(value: dict[str, Any]) -> list[str]:
    protocol_schema, _, _, fixture_validator = _schemas()
    registry = fixture_validator._registry  # type: ignore[attr-defined]
    document_validators = {
        kind: Draft202012Validator(
            {"$ref": f"{protocol_schema['$id']}#/$defs/{kind}"},
            registry=registry,
            format_checker=FormatChecker(),
        )
        for kind in ("message", "prompt", "receipt", "messageAck", "receiptAck")
    }
    errors = [
        f"fixture: {error.message}"
        for error in sorted(
            fixture_validator.iter_errors(value), key=lambda item: list(item.path)
        )
    ]
    if errors:
        return errors

    messages: dict[str, tuple[str, dict[str, Any]]] = {}
    prompts: dict[
        str, tuple[str, dict[str, Any], str, bool, str | None]
    ] = {}
    receipts: dict[str, tuple[str, dict[str, Any]]] = {}
    prompt_receipt_actions: dict[str, list[str]] = {}
    latest_watermark: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    capture_bindings: dict[str, tuple[dict[str, Any], dict[str, Any]]] = {}
    lineage_bindings: dict[
        tuple[str, str], tuple[dict[str, Any], dict[str, Any]]
    ] = {}
    message_deliveries = 0
    prompt_deliveries = 0
    receipt_deliveries = 0
    displays = 0
    logical_dispositions: list[str] = []
    assessments: set[str] = set()
    message_ack_statuses: list[str] = []
    receipt_ack_statuses: list[str] = []
    no_prompt_responses = 0

    for index, event in enumerate(value["events"]):
        if event["kind"] == "receive_no_prompt":
            no_prompt_responses += 1
            query = event["query"]
            if not any(
                message["scope"]
                == {
                    "companyId": query["companyId"],
                    "areaId": query["areaId"],
                    "processId": query["processId"],
                    "deviceId": query["deviceId"],
                }
                and message["captureId"] == query["captureId"]
                and message["labelId"] == query["labelId"]
                for _, message in messages.values()
            ):
                errors.append(
                    f"events/{index}/receive_no_prompt: query selects an unknown lineage"
                )
            continue
        document = event["document"]
        document_type = document["documentType"]
        where = f"events/{index}/{document_type}"
        errors.extend(
            _strict_document_errors(
                document,
                event["canonicalBytes"],
                document_validators[document_type],
                where,
            )
        )
        if document_type == "message":
            message_deliveries += 1
            errors.extend(_message_semantic_errors(document, where))
            identifier = document["messageId"]
            prior = messages.get(identifier)
            collision = prior is not None and prior[0] != document["contentDigest"]
            exact_duplicate = prior is not None and not collision
            if event["transportResult"] == "id_collision":
                if not collision:
                    errors.append(f"{where}: HTTP 409 without an actual messageId collision")
                continue
            if collision:
                errors.append(f"{where}: messageId collision with different content")
            else:
                messages.setdefault(identifier, (document["contentDigest"], document))
            capture_id = document["captureId"]
            binding = (document["scope"], document["producer"])
            if capture_id in capture_bindings and capture_bindings[capture_id] != binding:
                errors.append(f"{where}: captureId was rebound to another scope/producer")
            else:
                capture_bindings.setdefault(capture_id, binding)
            lineage_key = (capture_id, document["labelId"])
            if (
                lineage_key in lineage_bindings
                and lineage_bindings[lineage_key] != binding
            ):
                errors.append(f"{where}: label lineage was rebound to another scope/producer")
            else:
                lineage_bindings.setdefault(lineage_key, binding)
            watermark_key = (
                capture_id,
                document["labelId"],
                _jcs(document["scope"]),
                _jcs(document["producer"]),
            )
            previous = latest_watermark.get(watermark_key)
            relation = (
                "dominates"
                if previous is None
                else _watermark_relation(document["inputWatermark"], previous)
            )
            if exact_duplicate:
                expected_status = "exact_duplicate"
            elif previous is not None and previous.get("captureCommit") is not None:
                expected_status = "final_barrier"
            elif relation == "dominated":
                expected_status = "stale"
            elif relation == "incomparable":
                expected_status = "incomparable"
            else:
                expected_status = "stored"
            response = event["ackResponse"]
            response_where = f"events/{index}/message_ack"
            errors.extend(
                _strict_response_errors(
                    response,
                    event["responseCanonicalBytes"],
                    document_validators["messageAck"],
                    response_where,
                )
            )
            if (
                response["messageId"] != identifier
                or response["contentDigest"] != document["contentDigest"]
            ):
                errors.append(f"{response_where}: acknowledgement echo mismatch")
            if response["status"] != expected_status:
                errors.append(
                    f"{response_where}: status {response['status']} differs from {expected_status}"
                )
            message_ack_statuses.append(response["status"])
            if (
                not exact_duplicate
                and not collision
                and expected_status == "stored"
                and (previous is None or relation == "dominates")
            ):
                latest_watermark[watermark_key] = document["inputWatermark"]
        elif document_type == "prompt":
            prompt_deliveries += 1
            expected_query = {
                **document["scope"],
                "captureId": document["captureId"],
                "labelId": document["labelId"],
            }
            if event.get("query") != expected_query:
                errors.append(f"{where}: GET query does not bind the exact prompt lineage")
            errors.extend(
                _identity_vector_errors(
                    document["inputWatermark"], f"{where}/inputWatermark"
                )
            )
            if document["captureId"] != document["inputWatermark"]["captureId"]:
                errors.append(f"{where}: captureId differs from input watermark")
            sources: list[dict[str, Any]] = []
            for source_id in document["sourceMessageIds"]:
                source = messages.get(source_id)
                if source is None:
                    errors.append(f"{where}: sourceMessageId was not durably received")
                else:
                    sources.append(source[1])
            for source in sources:
                if (
                    source["scope"] != document["scope"]
                    or source["captureId"] != document["captureId"]
                    or source["labelId"] != document["labelId"]
                ):
                    errors.append(f"{where}: prompt scope differs from its source message")
            if not any(
                source["inputWatermark"] == document["inputWatermark"]
                for source in sources
            ):
                errors.append(f"{where}: prompt watermark is not an exact source watermark")
            identifier = document["promptId"]
            prior = prompts.get(identifier)
            if prior is not None:
                if prior[0] != document["contentDigest"]:
                    errors.append(f"{where}: promptId collision with different content")
                if event["displayed"]:
                    errors.append(f"{where}: equal prompt redelivery displayed twice")
                if event["disposition"] != prior[2]:
                    errors.append(f"{where}: equal prompt redelivery changed disposition")
            else:
                current = None
                if sources:
                    current = latest_watermark.get(
                        (
                            document["captureId"],
                            document["labelId"],
                            _jcs(document["scope"]),
                            _jcs(sources[0]["producer"]),
                        )
                    )
                recovery_state = event.get("recoveryState")
                expected = (
                    "interrupted_capture"
                    if recovery_state in {"intent_only", "received_only"}
                    else "shown"
                )
                if (
                    recovery_state is None
                    and current is not None
                    and current.get("captureCommit") is not None
                ):
                    expected = "committed_capture"
                elif (
                    recovery_state is None
                    and current is not None
                    and _watermark_relation(
                    document["inputWatermark"], current
                    ) in {"dominated", "incomparable"}
                ):
                    expected = "stale_watermark"
                if event["disposition"] != expected:
                    errors.append(
                        f"{where}: disposition {event['disposition']} differs from {expected}"
                    )
                if event["displayed"] != (expected == "shown"):
                    errors.append(f"{where}: display flag differs from disposition")
                prompts[identifier] = (
                    document["contentDigest"],
                    document,
                    event["disposition"],
                    event["displayed"],
                    recovery_state,
                )
                logical_dispositions.append(event["disposition"])
                assessments.add(document["assessmentRef"]["assessmentId"])
            displays += int(event["displayed"])
        elif document_type == "receipt":
            receipt_deliveries += 1
            logical_receipt = document["receiptId"] not in receipts
            errors.extend(
                _identity_vector_errors(
                    document["inputWatermark"], f"{where}/inputWatermark"
                )
            )
            occurred_at = datetime.fromisoformat(
                document["occurredAt"].replace("Z", "+00:00")
            )
            recorded_at = datetime.fromisoformat(
                document["clientRecordedAt"].replace("Z", "+00:00")
            )
            if occurred_at > recorded_at:
                errors.append(f"{where}: occurredAt is after clientRecordedAt")
            if "promptId" in document:
                prompt_entry = prompts.get(document["promptId"])
                if prompt_entry is None:
                    errors.append(f"{where}: receipt references an unknown prompt")
                else:
                    prompt = prompt_entry[1]
                    if (
                        document["promptDigest"] != prompt["contentDigest"]
                        or document["scope"] != prompt["scope"]
                        or document["captureId"] != prompt["captureId"]
                        or document["labelId"] != prompt["labelId"]
                        or document["assessmentId"]
                        != prompt["assessmentRef"]["assessmentId"]
                        or document["inputWatermark"] != prompt["inputWatermark"]
                    ):
                        errors.append(
                            f"{where}: receipt does not bind the exact prompt context"
                        )
                    actions = prompt_receipt_actions.setdefault(document["promptId"], [])
                    if logical_receipt and not actions:
                        if prompt_entry[2] == "shown" and document["action"] != "shown":
                            errors.append(
                                f"{where}: first shown receipt has the wrong action"
                            )
                        if prompt_entry[2] != "shown" and (
                            document["action"] != "suppressed"
                            or document.get("suppressionReason") != prompt_entry[2]
                        ):
                            errors.append(
                                f"{where}: suppression receipt has the wrong reason"
                            )
                        canonical_types = [
                            item["interactionType"]
                            for item in document["canonicalInteractions"]
                        ]
                        recovery_state = prompt_entry[4]
                        if recovery_state == "intent_only" and canonical_types != [
                            "suppressed"
                        ]:
                            errors.append(
                                f"{where}: intent-only recovery invented prior evidence"
                            )
                        if recovery_state == "received_only" and canonical_types != [
                            "received",
                            "suppressed",
                        ]:
                            errors.append(
                                f"{where}: received-only recovery lost its received evidence"
                            )
                    elif logical_receipt and prompt_entry[2] != "shown":
                        errors.append(
                            f"{where}: a suppressed prompt gained a later user action"
                        )
                    elif logical_receipt and document["action"] not in {
                        "answered",
                        "dismissed",
                    }:
                        errors.append(f"{where}: invalid later prompt-bound action")
                    if (
                        logical_receipt
                        and document["action"] in {"answered", "dismissed"}
                        and any(
                            action in {"answered", "dismissed"}
                            for action in actions
                        )
                    ):
                        errors.append(
                            f"{where}: prompt has more than one terminal user action"
                        )
                    if logical_receipt:
                        actions.append(document["action"])
            else:
                lineage = lineage_bindings.get(
                    (document["captureId"], document["labelId"])
                )
                if lineage is None or lineage[0] != document["scope"]:
                    errors.append(
                        f"{where}: scope-control receipt does not bind a known lineage"
                    )
            identifier = document["receiptId"]
            prior = receipts.get(identifier)
            collision = prior is not None and prior[0] != document["contentDigest"]
            exact_duplicate = prior is not None and not collision
            if event["transportResult"] == "id_collision":
                if not collision:
                    errors.append(f"{where}: HTTP 409 without an actual receiptId collision")
                continue
            if collision:
                errors.append(f"{where}: receiptId collision with different content")
            else:
                receipts.setdefault(identifier, (document["contentDigest"], document))
            response = event["ackResponse"]
            response_where = f"events/{index}/receipt_ack"
            errors.extend(
                _strict_response_errors(
                    response,
                    event["responseCanonicalBytes"],
                    document_validators["receiptAck"],
                    response_where,
                )
            )
            if (
                response["receiptId"] != identifier
                or response["contentDigest"] != document["contentDigest"]
            ):
                errors.append(f"{response_where}: acknowledgement echo mismatch")
            expected_status = "exact_duplicate" if exact_duplicate else "stored"
            if response["status"] != expected_status:
                errors.append(
                    f"{response_where}: status {response['status']} differs from {expected_status}"
                )
            receipt_ack_statuses.append(response["status"])

    expected = value["expectedOutcome"]
    final_watermark = next(
        reversed(list(latest_watermark.values())), expected["finalWatermark"]
    )
    actual = {
        "messageDeliveries": message_deliveries,
        "uniqueMessages": len(messages),
        "assessments": len(assessments),
        "promptDeliveries": prompt_deliveries,
        "uniquePrompts": len(prompts),
        "promptDisplays": displays,
        "promptDispositions": logical_dispositions,
        "receiptDeliveries": receipt_deliveries,
        "uniqueReceipts": len(receipts),
        "messageAckStatuses": message_ack_statuses,
        "receiptAckStatuses": receipt_ack_statuses,
        "noPromptResponses": no_prompt_responses,
        "finalWatermark": final_watermark,
    }
    if expected != actual:
        errors.append("expectedOutcome differs from replayed Capture Coach delivery")
    if displays > 1:
        # Fixtures never resolve a shown prompt before another display. This is the protocol's
        # strict at-most-one outstanding proof, not a product-wide lifetime display cap.
        errors.append("fixture displayed more than one outstanding prompt")
    return errors


def _negative_self_check(fixture: dict[str, Any]) -> None:
    messages = [
        event for event in fixture["events"] if event["kind"] == "send_message"
    ]
    if messages:
        collision = deepcopy(fixture)
        target = next(
            event for event in collision["events"] if event["kind"] == "send_message"
        )
        conflicting = deepcopy(target)
        conflicting["document"]["createdAt"] = "2026-07-24T23:59:59.000Z"
        material = {
            key: item
            for key, item in conflicting["document"].items()
            if key != "contentDigest"
        }
        conflicting["document"]["contentDigest"] = _jcs_digest(material)
        conflicting["canonicalBytes"] = _jcs(conflicting["document"])
        collision["events"].insert(1, conflicting)
        errors = validate_capture_coach_fixture(collision)
        if not any("messageId collision" in error for error in errors):
            raise ValueError("negative self-check accepted a messageId content collision")

    for unsafe in (9_007_199_254_740_992, -9_007_199_254_740_992):
        try:
            _jcs({"unsafe": unsafe})
        except ValueError:
            continue
        raise ValueError("negative self-check accepted an unsafe I-JSON integer")


def _jcs_live_self_check() -> None:
    _jcs_self_check()
    vector = {
        "\U0001f600": "non-BMP key and string \U0001f680",
        "\ufffd": "replacement",
        "z": 9_007_199_254_740_991,
    }
    expected = (
        '{"z":9007199254740991,"😀":"non-BMP key and string 🚀","�":"replacement"}'
    )
    if _jcs(vector) != expected:
        raise ValueError("live Coach JCS non-BMP/safe-integer vector failed")


def validate_all_capture_coach_fixtures() -> int:
    failures = 0
    try:
        _schemas()
        _jcs_live_self_check()
    except (OSError, TypeError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print(f"FAIL  capture Coach live schemas/JCS: {exc}", file=sys.stderr)
        return 1
    paths = sorted(FIXTURE_DIR.glob("*.json"))
    if not paths:
        print("FAIL  no Capture Coach live fixtures found", file=sys.stderr)
        return 1
    for path in paths:
        try:
            fixture = json.loads(path.read_text(encoding="utf-8"))
            errors = validate_capture_coach_fixture(fixture)
            if errors:
                failures += 1
                print(f"FAIL  coach/{path.name}", file=sys.stderr)
                for error in errors:
                    print(f"      {error}", file=sys.stderr)
                continue
            _negative_self_check(fixture)
        except (OSError, TypeError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            failures += 1
            print(f"FAIL  coach/{path.name}: {exc}", file=sys.stderr)
        else:
            print(f"ok    coach/{path.name}")
    return failures


def main() -> int:
    return int(validate_all_capture_coach_fixtures() > 0)


if __name__ == "__main__":
    raise SystemExit(main())
