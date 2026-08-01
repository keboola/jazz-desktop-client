#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Generate byte-exact Capture Coach live advisory conformance fixtures."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

LIVE_DIR = Path(__file__).resolve().parent
FIXTURE_DIR = LIVE_DIR / "coach" / "fixtures"
sys.path.insert(0, str(LIVE_DIR.parent / "archive"))
from validate_archives import _jcs as _archive_jcs  # noqa: E402


def _jcs(value: object) -> str:
    return _archive_jcs(value)


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _sha256_text(value: str) -> str:
    return _sha256_bytes(value.encode("utf-8"))


def _content_address(document: dict[str, Any]) -> dict[str, Any]:
    material = {key: value for key, value in document.items() if key != "contentDigest"}
    return {**material, "contentDigest": _sha256_text(_jcs(material))}


def _watermark(
    *,
    capture_id: str,
    streams: list[tuple[str, int]],
    transcripts: list[dict[str, Any]],
    commit: tuple[str, str] | None = None,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "schemaVersion": 2,
        "captureId": capture_id,
        "streams": [
            {"streamId": stream_id, "throughSequence": sequence}
            for stream_id, sequence in sorted(streams)
        ],
        "transcripts": sorted(transcripts, key=lambda item: item["transcriptId"]),
    }
    if commit is not None:
        value["captureCommit"] = {
            "captureCommitId": commit[0],
            "contentDigest": commit[1],
        }
    return value


def _message(
    *,
    message_id: str,
    capture_id: str,
    label_id: str,
    created_at: str,
    watermark: dict[str, Any],
    evidence: list[dict[str, Any]],
    scope: dict[str, str],
    producer: dict[str, Any],
) -> dict[str, Any]:
    return _content_address(
        {
            "documentType": "message",
            "schemaVersion": 1,
            "messageId": message_id,
            "scope": scope,
            "producer": producer,
            "captureId": capture_id,
            "labelId": label_id,
            "createdAt": created_at,
            "inputWatermark": watermark,
            "evidence": evidence,
        }
    )


def _prompt(
    *,
    prompt_id: str,
    capture_id: str,
    label_id: str,
    source_message_ids: list[str],
    assessment_id: str,
    revision: int,
    watermark: dict[str, Any],
    text: str,
    slot: str,
    issued_at: str,
    scope: dict[str, str],
) -> dict[str, Any]:
    return _content_address(
        {
            "documentType": "prompt",
            "schemaVersion": 1,
            "promptId": prompt_id,
            "scope": scope,
            "captureId": capture_id,
            "labelId": label_id,
            "sourceMessageIds": sorted(source_message_ids),
            "assessmentRef": {
                "assessmentId": assessment_id,
                "revision": revision,
                "inputDigest": _sha256_text(
                    "assessment-input:" + _jcs(watermark)
                ),
            },
            "inputWatermark": watermark,
            "snapshot": {
                "text": text,
                "slot": slot,
                "policyVersion": "capture-coach-live-policy/v1",
                "responseModes": ["typed_text", "spoken"],
            },
            "issuedAt": issued_at,
        }
    )


def _receipt(
    *,
    receipt_id: str,
    prompt: dict[str, Any],
    action: str,
    interaction_ids: list[str],
    occurred_at: str,
    client_recorded_at: str,
    suppression_reason: str | None = None,
    interaction_types: list[str] | None = None,
) -> dict[str, Any]:
    if interaction_types is None:
        interaction_types = (
            ["received", "shown"]
            if action == "shown"
            else [action]
        )
    value = {
        "documentType": "receipt",
        "schemaVersion": 1,
        "receiptId": receipt_id,
        "scope": prompt["scope"],
        "promptId": prompt["promptId"],
        "promptDigest": prompt["contentDigest"],
        "captureId": prompt["captureId"],
        "labelId": prompt["labelId"],
        "assessmentId": prompt["assessmentRef"]["assessmentId"],
        "inputWatermark": prompt["inputWatermark"],
        "action": action,
        "canonicalInteractions": [
            {
                "interactionId": interaction_id,
                "interactionType": interaction_type,
            }
            for interaction_id, interaction_type in zip(
                interaction_ids,
                interaction_types,
                strict=True,
            )
        ],
        "occurredAt": occurred_at,
        "clientRecordedAt": client_recorded_at,
    }
    if suppression_reason is not None:
        value["suppressionReason"] = suppression_reason
    return _content_address(value)


def _event(
    kind: str,
    document: dict[str, Any],
    transport_result: str,
    *,
    ack_status: str | None = None,
    displayed: bool | None = None,
    disposition: str | None = None,
    recovery_state: str | None = None,
) -> dict[str, Any]:
    route = {
        "send_message": ("POST", "/api/capture-coach/live/messages"),
        "receive_prompt": ("GET", "/api/capture-coach/live/prompts/next"),
        "send_receipt": ("POST", "/api/capture-coach/live/receipts"),
    }[kind]
    value: dict[str, Any] = {
        "kind": kind,
        "method": route[0],
        "endpoint": route[1],
        "document": document,
        "canonicalBytes": _jcs(document),
        "transportResult": transport_result,
        "httpStatus": 200,
    }
    if kind == "receive_prompt":
        value["query"] = _prompt_selector(document)
    if kind == "send_message":
        assert ack_status is not None
        response = {
            "documentType": "message_ack",
            "schemaVersion": 1,
            "messageId": document["messageId"],
            "contentDigest": document["contentDigest"],
            "status": ack_status,
        }
        value["ackResponse"] = response
        value["responseCanonicalBytes"] = _jcs(response)
    elif kind == "send_receipt":
        assert ack_status is not None
        response = {
            "documentType": "receipt_ack",
            "schemaVersion": 1,
            "receiptId": document["receiptId"],
            "contentDigest": document["contentDigest"],
            "status": ack_status,
        }
        value["ackResponse"] = response
        value["responseCanonicalBytes"] = _jcs(response)
    if displayed is not None:
        value["displayed"] = displayed
    if disposition is not None:
        value["disposition"] = disposition
    if recovery_state is not None:
        value["recoveryState"] = recovery_state
    return value


def _prompt_selector(prompt: dict[str, Any]) -> dict[str, Any]:
    return {
        **prompt["scope"],
        "captureId": prompt["captureId"],
        "labelId": prompt["labelId"],
    }


def _no_prompt_event(prompt: dict[str, Any]) -> dict[str, Any]:
    return {
        "kind": "receive_no_prompt",
        "method": "GET",
        "endpoint": "/api/capture-coach/live/prompts/next",
        "query": _prompt_selector(prompt),
        "transportResult": "no_body",
        "httpStatus": 204,
        "bodyByteLength": 0,
    }


def _id_collision_event(kind: str, document: dict[str, Any]) -> dict[str, Any]:
    assert kind in {"send_message", "send_receipt"}
    return {
        "kind": kind,
        "method": "POST",
        "endpoint": (
            "/api/capture-coach/live/messages"
            if kind == "send_message"
            else "/api/capture-coach/live/receipts"
        ),
        "document": document,
        "canonicalBytes": _jcs(document),
        "transportResult": "id_collision",
        "httpStatus": 409,
        "bodyByteLength": 0,
    }


def _fixture(
    scenario: str,
    events: list[dict[str, Any]],
    final_watermark: dict[str, Any],
) -> dict[str, Any]:
    messages = [event for event in events if event["kind"] == "send_message"]
    prompts = [event for event in events if event["kind"] == "receive_prompt"]
    receipts = [event for event in events if event["kind"] == "send_receipt"]
    prompt_dispositions: list[str] = []
    seen_prompt_ids: set[str] = set()
    for event in prompts:
        prompt_id = event["document"]["promptId"]
        if prompt_id in seen_prompt_ids:
            continue
        seen_prompt_ids.add(prompt_id)
        prompt_dispositions.append(event["disposition"])
    return {
        "protocol": "dev.jazz.capture-coach-live",
        "protocolVersion": 1,
        "scenario": scenario,
        "events": events,
        "expectedOutcome": {
            "messageDeliveries": len(messages),
            "uniqueMessages": len(
                {event["document"]["messageId"] for event in messages}
            ),
            "assessments": len(
                {
                    event["document"]["assessmentRef"]["assessmentId"]
                    for event in prompts
                }
            ),
            "promptDeliveries": len(prompts),
            "uniquePrompts": len(
                {event["document"]["promptId"] for event in prompts}
            ),
            "promptDisplays": sum(bool(event["displayed"]) for event in prompts),
            "promptDispositions": prompt_dispositions,
            "receiptDeliveries": len(receipts),
            "uniqueReceipts": len(
                {event["document"]["receiptId"] for event in receipts}
            ),
            "messageAckStatuses": [
                event["ackResponse"]["status"] for event in messages
                if "ackResponse" in event
            ],
            "receiptAckStatuses": [
                event["ackResponse"]["status"] for event in receipts
                if "ackResponse" in event
            ],
            "noPromptResponses": sum(
                event["kind"] == "receive_no_prompt" for event in events
            ),
            "finalWatermark": final_watermark,
        },
    }


def _lost_ack_fixture() -> dict[str, Any]:
    capture_id = "cap-0190a001-0000-7000-8000-000000000001"
    label_id = "l-0190a001-0000-7000-8000-000000000002"
    stream_id = "stream-0190a001-0000-7000-8000-000000000003"
    transcript_id = "transcript-native-0190a001"
    scope = {
        "companyId": "company-001",
        "areaId": "area-finance",
        "processId": "process-invoice-approval",
        "deviceId": "device-macos-001",
    }
    producer = {
        "producerId": "producer-macos-001",
        "kind": "native_desktop",
        "version": "1.0.0",
        "capabilities": ["accessibility", "screen_preview", "transcript"],
        "unavailableCapabilities": [],
    }
    text = "I approve the invoice when the balance is zero."
    watermark = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 3)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 1,
                "throughMillis": 5000,
                "textDigest": _sha256_text(text),
                "finalized": False,
            }
        ],
    )
    message = _message(
        message_id="ccm-0190a001-0000-7000-8000-000000000004",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T08:00:05.000Z",
        watermark=watermark,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 5000,
                "text": text,
                "textDigest": _sha256_text(text),
                "finalized": False,
            }
        ],
    )
    prompt = _prompt(
        prompt_id="prompt-0190a001-0000-7000-8000-000000000005",
        capture_id=capture_id,
        label_id=label_id,
        source_message_ids=[message["messageId"]],
        assessment_id="cqa-0190a001-0000-7000-8000-000000000006",
        revision=1,
        watermark=watermark,
        text="What happens when the balance is not zero?",
        slot="exception",
        issued_at="2026-07-24T08:00:05.200Z",
        scope=scope,
    )
    receipt = _receipt(
        receipt_id="ccr-0190a001-0000-7000-8000-000000000007",
        prompt=prompt,
        action="shown",
        interaction_ids=[
            "coach-0190a001-0000-7000-8000-000000000008",
            "coach-0190a001-0000-7000-8000-000000000009",
        ],
        occurred_at="2026-07-24T08:00:05.220Z",
        client_recorded_at="2026-07-24T08:00:05.230Z",
    )
    answer_receipt = _receipt(
        receipt_id="ccr-0190a001-0000-7000-8000-00000000000a",
        prompt=prompt,
        action="answered",
        interaction_ids=["coach-0190a001-0000-7000-8000-00000000000b"],
        occurred_at="2026-07-24T08:00:08.000Z",
        client_recorded_at="2026-07-24T08:00:08.010Z",
    )
    events = [
        _event("send_message", message, "ack_lost", ack_status="stored"),
        _event(
            "send_message",
            message,
            "accepted",
            ack_status="exact_duplicate",
        ),
        _event(
            "receive_prompt",
            prompt,
            "delivered",
            displayed=True,
            disposition="shown",
        ),
        _event(
            "receive_prompt",
            prompt,
            "delivered",
            displayed=False,
            disposition="shown",
        ),
        _event("send_receipt", receipt, "ack_lost", ack_status="stored"),
        _event(
            "send_receipt",
            receipt,
            "accepted",
            ack_status="exact_duplicate",
        ),
        _event(
            "send_receipt",
            answer_receipt,
            "accepted",
            ack_status="stored",
        ),
    ]
    return _fixture("lost_ack", events, watermark)


def _meeting_fixture() -> dict[str, Any]:
    capture_id = "cap-0190a002-0000-7000-8000-000000000001"
    label_id = "l-0190a002-0000-7000-8000-000000000002"
    video_stream = "stream-0190a002-0000-7000-8000-000000000003"
    transcript_stream = "stream-0190a002-0000-7000-8000-000000000004"
    transcript_id = "transcript-meeting-0190a002"
    scope = {
        "companyId": "company-001",
        "areaId": "area-procurement",
        "processId": "process-purchase-order",
        "deviceId": "device-meeting-ingress-001",
    }
    producer = {
        "producerId": "producer-meeting-001",
        "kind": "meeting_source",
        "version": "1.0.0",
        "capabilities": ["meeting_audio", "screen_share_video", "transcript"],
        "unavailableCapabilities": [
            "native_accessibility",
            "native_keyboard",
            "native_pointer",
        ],
    }
    text = "The shared screen shows the approved purchase order."
    audio = b"\x00\x01\x02\x03\x04\x05\x06\x07"
    preview = b"\x89PNG\r\n\x1a\ncoach-preview"
    watermark = _watermark(
        capture_id=capture_id,
        streams=[(video_stream, 2), (transcript_stream, 0)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 1,
                "throughMillis": 3200,
                "textDigest": _sha256_text(text),
                "finalized": False,
            }
        ],
    )
    message = _message(
        message_id="ccm-0190a002-0000-7000-8000-000000000005",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T09:00:03.200Z",
        watermark=watermark,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "canonicalObservation",
                "observationId": "obs-0190a002-0000-7000-8000-000000000006",
                "streamId": video_stream,
                "streamSequence": 2,
                "recordType": "jazz.media-observation",
                "recordDigest": "1" * 64,
                "sanitizedContext": {
                    "documentKind": "screen_share",
                    "action": "shared_screen_frame",
                    "payloadSummary": "Approved purchase order is visible.",
                    "redactionPolicyVersion": "meeting-consent-v1",
                    "maskedFields": [],
                },
                "preview": {
                    "mediaType": "image/png",
                    "byteLength": len(preview),
                    "contentSha256": _sha256_bytes(preview),
                    "contentBase64": base64.b64encode(preview).decode("ascii"),
                    "privacy": {
                        "policyVersion": "meeting-consent-v1",
                        "status": "no_sensitive_content",
                        "redactionCount": 0,
                    },
                },
            },
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 3200,
                "text": text,
                "textDigest": _sha256_text(text),
                "finalized": False,
            },
            {
                "kind": "audioChunk",
                "chunkId": "cac-0190a002-0000-7000-8000-000000000007",
                "streamId": transcript_stream,
                "streamSequence": 0,
                "startMillis": 0,
                "endMillis": 250,
                "mediaType": "audio/l16;rate=16000;channels=1",
                "byteLength": len(audio),
                "contentSha256": _sha256_bytes(audio),
                "contentBase64": base64.b64encode(audio).decode("ascii"),
            },
        ],
    )
    prompt = _prompt(
        prompt_id="prompt-0190a002-0000-7000-8000-000000000008",
        capture_id=capture_id,
        label_id=label_id,
        source_message_ids=[message["messageId"]],
        assessment_id="cqa-0190a002-0000-7000-8000-000000000009",
        revision=1,
        watermark=watermark,
        text="How do you verify that the purchase order is approved?",
        slot="success",
        issued_at="2026-07-24T09:00:03.400Z",
        scope=scope,
    )
    receipt = _receipt(
        receipt_id="ccr-0190a002-0000-7000-8000-00000000000a",
        prompt=prompt,
        action="shown",
        interaction_ids=[
            "coach-0190a002-0000-7000-8000-00000000000b",
            "coach-0190a002-0000-7000-8000-00000000000c",
        ],
        occurred_at="2026-07-24T09:00:03.420Z",
        client_recorded_at="2026-07-24T09:00:03.430Z",
    )
    events = [
        _event("send_message", message, "accepted", ack_status="stored"),
        _event(
            "receive_prompt",
            prompt,
            "delivered",
            displayed=True,
            disposition="shown",
        ),
        _event("send_receipt", receipt, "accepted", ack_status="stored"),
    ]
    return _fixture("meeting_source", events, watermark)


def _finalize_fixture() -> dict[str, Any]:
    capture_id = "cap-0190a003-0000-7000-8000-000000000001"
    label_id = "l-0190a003-0000-7000-8000-000000000002"
    stream_id = "stream-0190a003-0000-7000-8000-000000000003"
    transcript_id = "transcript-native-0190a003"
    scope = {
        "companyId": "company-001",
        "areaId": "area-finance",
        "processId": "process-invoice-handoff",
        "deviceId": "device-macos-003",
    }
    producer = {
        "producerId": "producer-macos-003",
        "kind": "native_desktop",
        "version": "1.0.0",
        "capabilities": ["accessibility", "transcript"],
        "unavailableCapabilities": ["screen_preview"],
    }
    partial_one = "I send the invoice"
    partial_two = "I send the invoice to Finance after approval"
    final_text = "I send the invoice to Finance after approval."
    first = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 2)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 1,
                "throughMillis": 2200,
                "textDigest": _sha256_text(partial_one),
                "finalized": False,
            }
        ],
    )
    second = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 4)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 2,
                "throughMillis": 4400,
                "textDigest": _sha256_text(partial_two),
                "finalized": False,
            }
        ],
    )
    final = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 5)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 2,
                "throughMillis": 4600,
                "textDigest": _sha256_text(final_text),
                "finalized": True,
                "contentDigest": _sha256_text(final_text),
            }
        ],
        commit=(
            "cmt-0190a003-0000-7000-8000-000000000004",
            "4" * 64,
        ),
    )
    messages = [
        _message(
            message_id=f"ccm-0190a003-0000-7000-8000-00000000000{suffix}",
            capture_id=capture_id,
            label_id=label_id,
            created_at=created_at,
            watermark=watermark,
            scope=scope,
            producer=producer,
            evidence=[
                {
                    "kind": "transcriptSpan",
                    "transcriptId": transcript_id,
                    "revision": revision,
                    "startMillis": 0,
                    "endMillis": end,
                    "text": text,
                    "textDigest": _sha256_text(text),
                    "finalized": finalized,
                }
            ],
        )
        for suffix, created_at, watermark, revision, end, text, finalized in [
            ("5", "2026-07-24T10:00:02.200Z", first, 1, 2200, partial_one, False),
            ("6", "2026-07-24T10:00:04.400Z", second, 2, 4400, partial_two, False),
            ("7", "2026-07-24T10:00:04.600Z", final, 2, 4600, final_text, True),
        ]
    ]
    incomparable_watermark = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 5)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 1,
                "throughMillis": 3000,
                "textDigest": _sha256_text("I send the invoice to"),
                "finalized": False,
            }
        ],
    )
    incomparable_message = _message(
        message_id="ccm-0190a003-0000-7000-8000-000000000010",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T10:00:04.450Z",
        watermark=incomparable_watermark,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 3000,
                "text": "I send the invoice to",
                "textDigest": _sha256_text("I send the invoice to"),
                "finalized": False,
            }
        ],
    )
    stale_message = _message(
        message_id="ccm-0190a003-0000-7000-8000-000000000011",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T10:00:04.460Z",
        watermark=first,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 2200,
                "text": partial_one,
                "textDigest": _sha256_text(partial_one),
                "finalized": False,
            }
        ],
    )
    colliding_message = _message(
        message_id=messages[0]["messageId"],
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T10:00:02.201Z",
        watermark=first,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 2200,
                "text": partial_one,
                "textDigest": _sha256_text(partial_one),
                "finalized": False,
            }
        ],
    )
    after_commit_watermark = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 6)],
        transcripts=final["transcripts"],
        commit=(
            "cmt-0190a003-0000-7000-8000-000000000004",
            "4" * 64,
        ),
    )
    after_commit_message = _message(
        message_id="ccm-0190a003-0000-7000-8000-000000000012",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T10:00:04.650Z",
        watermark=after_commit_watermark,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 2,
                "startMillis": 0,
                "endMillis": 4600,
                "text": final_text,
                "textDigest": _sha256_text(final_text),
                "finalized": True,
            }
        ],
    )
    stale_prompt = _prompt(
        prompt_id="prompt-0190a003-0000-7000-8000-000000000008",
        capture_id=capture_id,
        label_id=label_id,
        source_message_ids=[messages[0]["messageId"]],
        assessment_id="cqa-0190a003-0000-7000-8000-000000000009",
        revision=1,
        watermark=first,
        text="Who receives the invoice?",
        slot="handoff",
        issued_at="2026-07-24T10:00:04.700Z",
        scope=scope,
    )
    committed_prompt = _prompt(
        prompt_id="prompt-0190a003-0000-7000-8000-00000000000a",
        capture_id=capture_id,
        label_id=label_id,
        source_message_ids=[messages[2]["messageId"]],
        assessment_id="cqa-0190a003-0000-7000-8000-00000000000b",
        revision=1,
        watermark=final,
        text="What happens after Finance receives it?",
        slot="handoff",
        issued_at="2026-07-24T10:00:04.800Z",
        scope=scope,
    )
    stale_receipt = _receipt(
        receipt_id="ccr-0190a003-0000-7000-8000-00000000000c",
        prompt=stale_prompt,
        action="suppressed",
        interaction_ids=["coach-0190a003-0000-7000-8000-00000000000d"],
        occurred_at="2026-07-24T10:00:04.710Z",
        client_recorded_at="2026-07-24T10:00:04.720Z",
        suppression_reason="stale_watermark",
    )
    committed_receipt = _receipt(
        receipt_id="ccr-0190a003-0000-7000-8000-00000000000e",
        prompt=committed_prompt,
        action="suppressed",
        interaction_ids=["coach-0190a003-0000-7000-8000-00000000000f"],
        occurred_at="2026-07-24T10:00:04.810Z",
        client_recorded_at="2026-07-24T10:00:04.820Z",
        suppression_reason="committed_capture",
    )
    events = [
        _event(
            "send_message",
            messages[0],
            "accepted",
            ack_status="stored",
        ),
        _id_collision_event("send_message", colliding_message),
        _event(
            "send_message",
            messages[1],
            "accepted",
            ack_status="stored",
        ),
        _event(
            "send_message",
            incomparable_message,
            "accepted",
            ack_status="incomparable",
        ),
        _event(
            "send_message",
            stale_message,
            "accepted",
            ack_status="stale",
        ),
        _event(
            "receive_prompt",
            stale_prompt,
            "delivered",
            displayed=False,
            disposition="stale_watermark",
        ),
        _event(
            "send_receipt",
            stale_receipt,
            "accepted",
            ack_status="stored",
        ),
        _event(
            "send_message",
            messages[2],
            "accepted",
            ack_status="stored",
        ),
        _event(
            "send_message",
            after_commit_message,
            "accepted",
            ack_status="final_barrier",
        ),
        _event(
            "receive_prompt",
            committed_prompt,
            "delivered",
            displayed=False,
            disposition="committed_capture",
        ),
        _event(
            "send_receipt",
            committed_receipt,
            "accepted",
            ack_status="stored",
        ),
        _no_prompt_event(committed_prompt),
    ]
    return _fixture("finalize", events, final)


def _interrupted_recovery_fixture() -> dict[str, Any]:
    capture_id = "cap-0190a004-0000-7000-8000-000000000001"
    label_id = "l-0190a004-0000-7000-8000-000000000002"
    stream_id = "stream-0190a004-0000-7000-8000-000000000003"
    transcript_id = "transcript-native-0190a004"
    scope = {
        "companyId": "company-001",
        "areaId": "area-finance",
        "processId": "process-interrupted-recovery",
        "deviceId": "device-macos-004",
    }
    producer = {
        "producerId": "producer-macos-004",
        "kind": "native_desktop",
        "version": "1.0.0",
        "capabilities": ["accessibility", "transcript"],
        "unavailableCapabilities": [],
    }
    text = "I check the recovery queue before I continue."
    watermark = _watermark(
        capture_id=capture_id,
        streams=[(stream_id, 4)],
        transcripts=[
            {
                "transcriptId": transcript_id,
                "revision": 1,
                "throughMillis": 4000,
                "textDigest": _sha256_text(text),
                "finalized": False,
            }
        ],
    )
    message = _message(
        message_id="ccm-0190a004-0000-7000-8000-000000000004",
        capture_id=capture_id,
        label_id=label_id,
        created_at="2026-07-24T11:00:04.000Z",
        watermark=watermark,
        scope=scope,
        producer=producer,
        evidence=[
            {
                "kind": "transcriptSpan",
                "transcriptId": transcript_id,
                "revision": 1,
                "startMillis": 0,
                "endMillis": 4000,
                "text": text,
                "textDigest": _sha256_text(text),
                "finalized": False,
            }
        ],
    )
    prompt_specs = [
        (
            "prompt-0190a004-0000-7000-8000-000000000005",
            "cqa-0190a004-0000-7000-8000-000000000006",
            "Which queue state prevents the next step?",
            "intent_only",
        ),
        (
            "prompt-0190a004-0000-7000-8000-000000000009",
            "cqa-0190a004-0000-7000-8000-00000000000a",
            "Who resolves an interrupted item?",
            "received_only",
        ),
        (
            "prompt-0190a004-0000-7000-8000-00000000000e",
            "cqa-0190a004-0000-7000-8000-00000000000f",
            "How do you verify recovery succeeded?",
            "received_shown",
        ),
    ]
    prompts = [
        _prompt(
            prompt_id=prompt_id,
            capture_id=capture_id,
            label_id=label_id,
            source_message_ids=[message["messageId"]],
            assessment_id=assessment_id,
            revision=1,
            watermark=watermark,
            text=question,
            slot="exception",
            issued_at=f"2026-07-24T11:00:0{5 + index}.000Z",
            scope=scope,
        )
        for index, (prompt_id, assessment_id, question, _) in enumerate(
            prompt_specs
        )
    ]
    intent_only_receipt = _receipt(
        receipt_id="ccr-0190a004-0000-7000-8000-000000000007",
        prompt=prompts[0],
        action="suppressed",
        suppression_reason="interrupted_capture",
        interaction_ids=[
            "coach-0190a004-0000-7000-8000-000000000008"
        ],
        interaction_types=["suppressed"],
        occurred_at="2026-07-24T11:00:05.010Z",
        client_recorded_at="2026-07-24T11:00:05.010Z",
    )
    received_only_receipt = _receipt(
        receipt_id="ccr-0190a004-0000-7000-8000-00000000000b",
        prompt=prompts[1],
        action="suppressed",
        suppression_reason="interrupted_capture",
        interaction_ids=[
            "coach-0190a004-0000-7000-8000-00000000000c",
            "coach-0190a004-0000-7000-8000-00000000000d",
        ],
        interaction_types=["received", "suppressed"],
        occurred_at="2026-07-24T11:00:06.010Z",
        client_recorded_at="2026-07-24T11:00:06.010Z",
    )
    shown_receipt = _receipt(
        receipt_id="ccr-0190a004-0000-7000-8000-000000000010",
        prompt=prompts[2],
        action="shown",
        interaction_ids=[
            "coach-0190a004-0000-7000-8000-000000000011",
            "coach-0190a004-0000-7000-8000-000000000012",
        ],
        occurred_at="2026-07-24T11:00:07.010Z",
        client_recorded_at="2026-07-24T11:00:07.020Z",
    )
    events = [
        _event("send_message", message, "accepted", ack_status="stored"),
        _event(
            "receive_prompt",
            prompts[0],
            "delivered",
            displayed=False,
            disposition="interrupted_capture",
            recovery_state="intent_only",
        ),
        _event(
            "send_receipt",
            intent_only_receipt,
            "accepted",
            ack_status="stored",
        ),
        _event(
            "receive_prompt",
            prompts[1],
            "delivered",
            displayed=False,
            disposition="interrupted_capture",
            recovery_state="received_only",
        ),
        _event(
            "send_receipt",
            received_only_receipt,
            "accepted",
            ack_status="stored",
        ),
        _event(
            "receive_prompt",
            prompts[2],
            "delivered",
            displayed=True,
            disposition="shown",
            recovery_state="received_shown",
        ),
        _event(
            "send_receipt",
            shown_receipt,
            "accepted",
            ack_status="stored",
        ),
    ]
    return _fixture("interrupted_recovery", events, watermark)


def _render(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, indent=2, separators=(",", ": ")) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    fixtures = {
        "02-capture-coach-lost-ack.json": _lost_ack_fixture(),
        "03-capture-coach-meeting-source.json": _meeting_fixture(),
        "04-capture-coach-finalize.json": _finalize_fixture(),
        "05-capture-coach-interrupted-recovery.json":
            _interrupted_recovery_fixture(),
    }
    failures = 0
    FIXTURE_DIR.mkdir(parents=True, exist_ok=True)
    for name, fixture in fixtures.items():
        path = FIXTURE_DIR / name
        rendered = _render(fixture)
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != rendered:
                print(f"FAIL  {name} is not generated output")
                failures += 1
            else:
                print(f"ok    {name}")
        else:
            path.write_text(rendered, encoding="utf-8")
            print(f"updated {name}")
    return int(failures > 0)


if __name__ == "__main__":
    raise SystemExit(main())
