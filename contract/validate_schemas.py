#!/usr/bin/env python3
"""Validate the desktop-facing JSON Schemas without depending on either client."""

from __future__ import annotations

import json
import hashlib
import sys
from pathlib import Path

from jsonschema import FormatChecker
from jsonschema.validators import Draft202012Validator

CONTRACT_DIR = Path(__file__).resolve().parent
REQUIRED_KEYS = ("$schema", "$id", "title")
EXPECTED_DIALECT = "https://json-schema.org/draft/2020-12/schema"


def canonical_digest(value: object) -> str:
    """Fixture-safe JCS subset (all current guided vectors use integral JSON numbers)."""

    payload = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def guided_content_address_errors(value: dict[str, object]) -> list[str]:
    errors: list[str] = []
    decision = value.get("decision")
    if not isinstance(decision, dict):
        return ["decision is not an object"]
    request = decision.get("request")
    if not isinstance(request, dict):
        return ["decision.request is not an object"]
    expected_request = canonical_digest(request)
    if decision.get("requestDigest") != expected_request:
        errors.append("decision.requestDigest does not match request")
    context = {
        key: request[key]
        for key in (
            "capabilities",
            "preconditions",
            "applicationObservations",
            "businessObjectInputs",
            "locatorResolution",
        )
        if key in request
    }
    trusted = decision.get("trustedRuntimeContext")
    if not isinstance(trusted, dict) or trusted.get(
        "requestContextDigest"
    ) != canonical_digest(context):
        errors.append("decision trusted runtime is not bound to request context")
    for index, approval in enumerate(request.get("approvals", [])):
        if not isinstance(approval, dict):
            errors.append(f"request.approvals[{index}] is not an object")
            continue
        approval_material = {
            key: item for key, item in approval.items() if key != "approvalId"
        }
        expected_id = "gra_" + canonical_digest(approval_material)[7:39]
        if approval.get("approvalId") != expected_id:
            errors.append(f"request.approvals[{index}].approvalId does not match content")
    decision_material = {
        key: item
        for key, item in decision.items()
        if key not in {"decisionId", "contentDigest"}
    }
    expected_decision = canonical_digest(decision_material)
    if decision.get("contentDigest") != expected_decision:
        errors.append("decision.contentDigest does not match content")
    if decision.get("decisionId") != "grd_" + expected_decision[7:39]:
        errors.append("decision.decisionId does not match content")
    if decision.get("status") == "ready" and decision.get(
        "logicalOperationKey"
    ) != request.get("idempotencyKey"):
        errors.append("ready decision does not bind the exact logical operation key")

    for index, receipt in enumerate(value.get("priorReceipts", [])):
        if not isinstance(receipt, dict):
            errors.append(f"priorReceipts[{index}] is not an object")
            continue
        receipt_material = {
            key: item
            for key, item in receipt.items()
            if key not in {"receiptId", "contentDigest"}
        }
        expected_receipt = canonical_digest(receipt_material)
        if receipt.get("contentDigest") != expected_receipt:
            errors.append(f"priorReceipts[{index}].contentDigest does not match content")
        if receipt.get("receiptId") != "ger_" + expected_receipt[7:39]:
            errors.append(f"priorReceipts[{index}].receiptId does not match content")
        result = {
            key: receipt[key]
            for key in (
                "status",
                "startedAt",
                "completedAt",
                "proofs",
                "postconditions",
                "branchDecision",
                "handoffOutcome",
                "sideEffects",
                "interventions",
                "result",
                "exception",
            )
            if key in receipt
        }
        completion = receipt.get("trustedCompletion")
        if not isinstance(completion, dict) or completion.get(
            "resultDigest"
        ) != canonical_digest(result):
            errors.append(f"priorReceipts[{index}] trusted completion is not bound to result")
    return errors


def main() -> int:
    failures = 0
    # Capture schemas now include nested contracts such as contract/archive/schema/. Validate every
    # schema under contract/, not only the original top-level schema directory.
    paths = sorted(CONTRACT_DIR.rglob("*.schema.json"))
    for path in paths:
        try:
            schema = json.loads(path.read_text(encoding="utf-8"))
            Draft202012Validator.check_schema(schema)
            missing = [key for key in REQUIRED_KEYS if not schema.get(key)]
            if schema.get("$schema") != EXPECTED_DIALECT:
                missing.append("a Draft 2020-12 $schema")
            if missing:
                raise ValueError(f"missing or invalid metadata: {', '.join(missing)}")
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures += 1
            print(f"FAIL  {path.relative_to(CONTRACT_DIR)}: {exc}", file=sys.stderr)
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)}")
    if not paths:
        print("FAIL  no schemas found", file=sys.stderr)
        return 1

    # Contract vectors are part of the schema contract too: every positive input must remain
    # accepted and every explicitly-invalid vector must remain rejected.
    activity_path = CONTRACT_DIR / "schema" / "activity-event.schema.json"
    activity_schema = json.loads(activity_path.read_text(encoding="utf-8"))
    activity = Draft202012Validator(activity_schema, format_checker=FormatChecker())
    for path in sorted((CONTRACT_DIR / "conformance" / "fixtures").glob("*.json")):
        root = json.loads(path.read_text(encoding="utf-8"))
        fixture_failed = False
        for index, event in enumerate(root.get("input", {}).get("events", [])):
            errors = list(activity.iter_errors(event))
            if errors:
                fixture_failed = True
                failures += 1
                print(
                    f"FAIL  {path.relative_to(CONTRACT_DIR)} event {index}: {errors[0].message}",
                    file=sys.stderr,
                )
        if not fixture_failed:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} events")
    for path in sorted((CONTRACT_DIR / "conformance" / "invalid").glob("*.json")):
        root = json.loads(path.read_text(encoding="utf-8"))
        if list(activity.iter_errors(root.get("event", {}))):
            print(f"ok    {path.relative_to(CONTRACT_DIR)} rejected")
        else:
            failures += 1
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} was unexpectedly accepted",
                file=sys.stderr,
            )

    execution_schema_path = (
        CONTRACT_DIR / "execution/schema/guided-execution-fixture.schema.json"
    )
    execution_schema = json.loads(execution_schema_path.read_text(encoding="utf-8"))
    execution = Draft202012Validator(
        execution_schema, format_checker=FormatChecker()
    )
    guided_schema_path = CONTRACT_DIR / "execution/schema/guided-replay.schema.json"
    guided_schema = json.loads(guided_schema_path.read_text(encoding="utf-8"))

    def guided_validator(definition: str) -> Draft202012Validator:
        return Draft202012Validator(
            {
                "$schema": EXPECTED_DIALECT,
                "$defs": guided_schema["$defs"],
                "$ref": f"#/$defs/{definition}",
            },
            format_checker=FormatChecker(),
        )

    guided_decision = guided_validator("decision")
    guided_receipt = guided_validator("executionReceipt")
    for path in sorted((CONTRACT_DIR / "execution/fixtures").glob("*.json")):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(execution.iter_errors(value), key=lambda error: list(error.path))
        errors.extend(
            sorted(
                guided_decision.iter_errors(value.get("decision", {})),
                key=lambda error: list(error.path),
            )
        )
        for receipt in value.get("priorReceipts", []):
            errors.extend(
                sorted(
                    guided_receipt.iter_errors(receipt),
                    key=lambda error: list(error.path),
                )
            )
        errors.extend(
            ValueError(message) for message in guided_content_address_errors(value)
        )
        if errors:
            failures += 1
            location = "/".join(str(part) for part in errors[0].path)
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} at {location}: {errors[0].message}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} guided execution")
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
