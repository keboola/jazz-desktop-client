#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["jsonschema>=4.23,<5"]
# ///
"""Validate the desktop-facing JSON Schemas without depending on either client."""

from __future__ import annotations

import base64
import binascii
import copy
import hashlib
import json
import sys
from pathlib import Path

from jsonschema import FormatChecker
from jsonschema.validators import Draft202012Validator
from referencing import Registry, Resource

from archive.validate_archives import _jcs, _jcs_self_check

CONTRACT_DIR = Path(__file__).resolve().parent
REQUIRED_KEYS = ("$schema", "$id", "title")
EXPECTED_DIALECT = "https://json-schema.org/draft/2020-12/schema"


def canonical_digest(value: object) -> str:
    """Return the normative RFC 8785 digest representation used by guided execution."""

    payload = _jcs(value).encode("utf-8")
    return "sha256:" + hashlib.sha256(payload).hexdigest()


def action_authority_digest_vector_errors() -> list[str]:
    source_path = (
        CONTRACT_DIR
        / "execution"
        / "digest-fixtures"
        / "action-authority-digest-vectors.json"
    )
    swift_path = (
        CONTRACT_DIR.parent
        / "macos"
        / "Tests"
        / "JazzCaptureCoreTests"
        / "Fixtures"
        / source_path.name
    )
    errors: list[str] = []
    try:
        source_bytes = source_path.read_bytes()
        swift_bytes = swift_path.read_bytes()
    except OSError as exc:
        return [f"cannot read digest vector or Swift mirror: {exc}"]
    if source_bytes != swift_bytes:
        errors.append("Swift action-authority digest vector mirror is not byte-identical")
    try:
        root = json.loads(source_bytes)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        return errors + [f"cannot decode action-authority digest vectors: {exc}"]
    if not isinstance(root, dict) or root.get("schemaVersion") != 1:
        return errors + ["action-authority digest vectors require schemaVersion 1"]
    vectors = root.get("vectors")
    if not isinstance(vectors, list) or not vectors:
        return errors + ["action-authority digest vectors must be a non-empty array"]
    names: set[str] = set()
    for index, vector in enumerate(vectors):
        where = f"action-authority digest vector {index}"
        if not isinstance(vector, dict):
            errors.append(f"{where} is not an object")
            continue
        name = vector.get("name")
        if not isinstance(name, str) or not name or name in names:
            errors.append(f"{where} has a missing or duplicate name")
        else:
            names.add(name)
            where = f"action-authority digest vector {name}"
        instruction = vector.get("instruction")
        if not isinstance(instruction, str):
            errors.append(f"{where} instruction is not a string")
            continue
        instruction_bytes = _jcs(instruction).encode("utf-8")
        if vector.get("instructionCanonicalJcs") != instruction_bytes.decode("utf-8"):
            errors.append(f"{where} instructionCanonicalJcs differs")
        if vector.get("instructionCanonicalUtf8Hex") != instruction_bytes.hex():
            errors.append(f"{where} instructionCanonicalUtf8Hex differs")
        if vector.get("instructionDigest") != canonical_digest(instruction):
            errors.append(f"{where} instructionDigest differs")
        if not any(ord(scalar) > 0xFFFF for scalar in instruction):
            errors.append(f"{where} does not exercise a non-BMP scalar")
        if "\u0301" not in instruction:
            errors.append(f"{where} does not exercise decomposed Unicode")

        preparation = vector.get("preparation")
        if not isinstance(preparation, dict):
            errors.append(f"{where} preparation is not an object")
            continue
        material = copy.deepcopy(preparation)
        expected_digest = material.pop("preparationDigest", None)
        if expected_digest != canonical_digest(material):
            errors.append(f"{where} preparationDigest differs")
        material_bytes = _jcs(material).encode("utf-8")
        if (
            vector.get("preparationMaterialCanonicalJcs")
            != material_bytes.decode("utf-8")
        ):
            errors.append(f"{where} preparationMaterialCanonicalJcs differs")
        if vector.get("preparationMaterialCanonicalUtf8Hex") != material_bytes.hex():
            errors.append(f"{where} preparationMaterialCanonicalUtf8Hex differs")
        authorized_step = preparation.get("authorizedStep")
        if not isinstance(authorized_step, dict) or authorized_step.get(
            "instructionDigest"
        ) != vector.get("instructionDigest"):
            errors.append(f"{where} preparation does not bind instructionDigest")
    return errors


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

    try:
        _jcs_self_check()
        digest_vector_errors = action_authority_digest_vector_errors()
    except (TypeError, ValueError) as exc:
        digest_vector_errors = [f"RFC 8785 digest validation failed: {exc}"]
    if digest_vector_errors:
        failures += len(digest_vector_errors)
        for error in digest_vector_errors:
            print(f"FAIL  execution digest vectors: {error}", file=sys.stderr)
    else:
        print("ok    execution action-authority digest vectors")

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

    enrollment_schema_dir = CONTRACT_DIR / "enrollment" / "schema"
    enrollment_schemas = [
        json.loads(path.read_text(encoding="utf-8"))
        for path in sorted(enrollment_schema_dir.glob("*.schema.json"))
    ]
    enrollment_registry = Registry().with_resources(
        [
            (schema["$id"], Resource.from_contents(schema))
            for schema in enrollment_schemas
        ]
    )
    enrollment_fixture_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/device-bundle-v2-fixture.schema.json")
    )
    enrollment_fixture = Draft202012Validator(
        enrollment_fixture_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    for path in sorted((CONTRACT_DIR / "enrollment" / "fixtures").glob("*.json")):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(
            enrollment_fixture.iter_errors(value),
            key=lambda error: list(error.path),
        )
        try:
            payload_segment = value["jws"]["payload"]
            padding = "=" * (-len(payload_segment) % 4)
            payload = json.loads(
                base64.b64decode(
                    payload_segment + padding,
                    altchars=b"-_",
                    validate=True,
                )
            )
            if payload != value["expectedPayload"]:
                errors.append(ValueError("JWS payload differs from expectedPayload"))
        except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
            errors.append(exc)
        if errors:
            failures += 1
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)}: {errors[0]}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} signed enrollment")

    mvp_bundle_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/device-bundle-mvp-v1.schema.json")
    )
    mvp_bundle = Draft202012Validator(
        mvp_bundle_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    for path in sorted((CONTRACT_DIR / "enrollment" / "mvp-fixtures").glob("*.json")):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(mvp_bundle.iter_errors(value), key=lambda error: list(error.path))
        if errors:
            failures += 1
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)}: {errors[0]}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} MVP enrollment")

    device_bound_fixture_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/device-bound-redemption-v1-fixture.schema.json")
    )
    device_bound_fixture = Draft202012Validator(
        device_bound_fixture_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    claim_payload_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/device-claim-v1-payload.schema.json")
    )
    claim_payload_validator = Draft202012Validator(
        claim_payload_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    sealed_protected_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/sealed-device-bundle-v1-protected.schema.json")
    )
    sealed_protected_validator = Draft202012Validator(
        sealed_protected_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    for path in sorted(
        (CONTRACT_DIR / "enrollment" / "device-bound" / "fixtures").glob("*.json")
    ):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(
            device_bound_fixture.iter_errors(value),
            key=lambda error: list(error.path),
        )
        try:
            claim_segment = value["claimEnvelope"]["payload"]
            claim_bytes = base64.b64decode(
                claim_segment + ("=" * (-len(claim_segment) % 4)),
                altchars=b"-_",
                validate=True,
            )
            claim_payload = json.loads(claim_bytes)
            canonical_claim = json.dumps(
                claim_payload,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            if canonical_claim != claim_bytes:
                errors.append(ValueError("claim payload is not canonical JSON"))
            if claim_payload != value["claimPayload"]:
                errors.append(ValueError("claim payload differs from claimPayload"))
            errors.extend(claim_payload_validator.iter_errors(claim_payload))

            protected_segment = value["sealedBundle"]["protected"]
            protected_bytes = base64.b64decode(
                protected_segment + ("=" * (-len(protected_segment) % 4)),
                altchars=b"-_",
                validate=True,
            )
            protected = json.loads(protected_bytes)
            canonical_protected = json.dumps(
                protected,
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            if canonical_protected != protected_bytes:
                errors.append(ValueError("sealed protected object is not canonical JSON"))
            errors.extend(sealed_protected_validator.iter_errors(protected))

            signed_segment = value["signedDeviceBundle"]
            signed_bytes = base64.b64decode(
                signed_segment + ("=" * (-len(signed_segment) % 4)),
                altchars=b"-_",
                validate=True,
            )
            sealed_bytes = json.dumps(
                value["sealedBundle"],
                ensure_ascii=False,
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
            expected = value["expected"]
            if hashlib.sha256(claim_bytes).hexdigest() != expected["claimSha256"]:
                errors.append(ValueError("claimSha256 does not match claim bytes"))
            if hashlib.sha256(signed_bytes).hexdigest() != expected["bundleSha256"]:
                errors.append(ValueError("bundleSha256 does not match signed bundle bytes"))
            if (
                hashlib.sha256(sealed_bytes).hexdigest()
                != expected["sealedBundleSha256"]
            ):
                errors.append(
                    ValueError("sealedBundleSha256 does not match sealed envelope bytes")
                )
            if protected["context"]["claimSha256"] != expected["claimSha256"]:
                errors.append(ValueError("protected context does not bind claim digest"))
            if protected["context"]["bundleSha256"] != expected["bundleSha256"]:
                errors.append(ValueError("protected context does not bind bundle digest"))
        except (
            KeyError,
            TypeError,
            ValueError,
            binascii.Error,
            json.JSONDecodeError,
        ) as exc:
            errors.append(exc)
        if errors:
            failures += 1
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)}: {errors[0]}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} device-bound enrollment")

    redemption_http_fixture_schema = next(
        schema
        for schema in enrollment_schemas
        if schema["$id"].endswith("/device-redemption-http-v1-fixture.schema.json")
    )
    redemption_http_fixture = Draft202012Validator(
        redemption_http_fixture_schema,
        registry=enrollment_registry,
        format_checker=FormatChecker(),
    )
    for path in sorted(
        (
            CONTRACT_DIR
            / "enrollment"
            / "device-bound"
            / "http-fixtures"
        ).glob("*.json")
    ):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(
            redemption_http_fixture.iter_errors(value),
            key=lambda error: list(error.path),
        )
        try:
            bootstrap = value["bootstrap"]
            context = value["context"]
            pending = value["pendingResponse"]
            ready = value["readyResponse"]
            for field in ("bootstrapId", "deviceId", "bundleId", "generation"):
                if context[field] != bootstrap[field] or pending[field] != bootstrap[field]:
                    errors.append(ValueError(f"HTTP fixture {field} lineage differs"))
            if context["expiresAt"] != bootstrap["expiresAt"]:
                errors.append(ValueError("HTTP context expiry differs from bootstrap"))
            if pending["expiresAt"] != bootstrap["expiresAt"]:
                errors.append(ValueError("HTTP pending expiry differs from bootstrap"))
            if ready["bootstrapExpiresAt"] != bootstrap["expiresAt"]:
                errors.append(ValueError("HTTP READY expiry differs from bootstrap"))
            if not bootstrap["redemptionURL"].endswith("/" + bootstrap["bootstrapId"]):
                errors.append(ValueError("HTTP bootstrap route differs from bootstrap id"))
            scope_material = {
                "schema": "jazz-device-enrollment-scope/v1",
                "deviceId": context["deviceId"],
                "companyId": context["companyId"],
                "areaId": context["areaId"],
                "projectId": context["projectId"],
            }
            expected_scope = canonical_digest(scope_material)[7:]
            if context["deviceScopeSHA256"] != expected_scope:
                errors.append(ValueError("HTTP context scope digest does not match scope"))
        except (KeyError, TypeError, ValueError) as exc:
            errors.append(exc)
        if errors:
            failures += 1
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)}: {errors[0]}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} redemption HTTP")

    execution_schema_path = (
        CONTRACT_DIR / "execution/schema/guided-execution-fixture.schema.json"
    )
    execution_schema = json.loads(execution_schema_path.read_text(encoding="utf-8"))
    execution = Draft202012Validator(
        execution_schema, format_checker=FormatChecker()
    )
    guided_schema_path = CONTRACT_DIR / "execution/schema/guided-replay.schema.json"
    guided_schema = json.loads(guided_schema_path.read_text(encoding="utf-8"))
    launch_schema_path = (
        CONTRACT_DIR / "execution/schema/guided-execution-launch.schema.json"
    )
    launch_schema = json.loads(launch_schema_path.read_text(encoding="utf-8"))
    refresh_schema_path = (
        CONTRACT_DIR / "execution/schema/guided-execution-refresh.schema.json"
    )
    refresh_schema = json.loads(refresh_schema_path.read_text(encoding="utf-8"))
    registry = Registry().with_resource(
        guided_schema["$id"],
        Resource.from_contents(guided_schema),
    )
    launch = Draft202012Validator(
        launch_schema,
        registry=registry,
        format_checker=FormatChecker(),
    )
    handoff = Draft202012Validator(
        {
            "$schema": EXPECTED_DIALECT,
            "$defs": launch_schema["$defs"],
            "$ref": "#/$defs/handoff",
        },
        registry=registry,
        format_checker=FormatChecker(),
    )
    refresh = Draft202012Validator(
        refresh_schema,
        registry=registry,
        format_checker=FormatChecker(),
    )
    refresh_response = Draft202012Validator(
        {
            "$schema": EXPECTED_DIALECT,
            "$defs": refresh_schema["$defs"],
            "$ref": "#/$defs/response",
        },
        registry=registry,
        format_checker=FormatChecker(),
    )

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
    handoff_fixtures: list[tuple[Path, dict[str, object]]] = []
    for path in sorted(
        (CONTRACT_DIR / "execution/handoff-fixtures").glob("*.json")
    ):
        value = json.loads(path.read_text(encoding="utf-8"))
        errors = sorted(
            handoff.iter_errors(value),
            key=lambda error: list(error.path),
        )
        capability = value.get("capability")
        handoff_id = value.get("handoffId")
        if (
            isinstance(capability, str)
            and isinstance(handoff_id, str)
            and not capability.startswith(f"{handoff_id}.")
        ):
            errors.append(
                ValueError("handoff capability does not belong to handoffId")
            )
        if errors:
            failures += 1
            first = errors[0]
            location = "/".join(
                str(part) for part in getattr(first, "path", ())
            )
            message = getattr(first, "message", str(first))
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} at {location}: {message}",
                file=sys.stderr,
            )
        else:
            handoff_fixtures.append((path, value))
            print(
                f"ok    {path.relative_to(CONTRACT_DIR)} replay handoff"
            )

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
        launch_value = {
            key: item
            for key, item in value.items()
            if key
            in {
                "protocolVersion",
                "approvedRunbook",
                "decision",
                "priorReceipts",
                "runtime",
            }
        }
        launch_value["protocol"] = "dev.jazz.guided-execution-launch"
        launch_errors = sorted(
            launch.iter_errors(launch_value),
            key=lambda error: list(error.path),
        )
        if launch_errors:
            failures += 1
            location = "/".join(str(part) for part in launch_errors[0].path)
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} launch at {location}: "
                f"{launch_errors[0].message}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} launch packet")
        preparation = copy.deepcopy(value["decision"])
        instruction = preparation["authorizedStep"].pop("instruction")
        preparation["authorizedStep"]["instructionDigest"] = canonical_digest(
            instruction
        )
        preparation["artifactType"] = "guidedReplayPreparation"
        preparation["schemaVersion"] = "2"
        preparation["actionAuthorityProtocol"] = "dev.jazz.action-authority"
        preparation["actionAuthorityProtocolVersion"] = 2
        preparation["preparationDigest"] = canonical_digest(preparation)
        for handoff_path, handoff_value in handoff_fixtures:
            decision = value.get("decision", {})
            request = decision.get("request", {})
            runbook = decision.get("runbook", {})
            expected_bindings = {
                "operatorId": request.get("operatorId"),
                "scope": runbook.get("scope"),
                "decisionId": decision.get("decisionId"),
                "decisionContentDigest": decision.get("contentDigest"),
                "executionId": request.get("executionId"),
                "runbookVersionId": runbook.get("runbookVersionId"),
                "runbookContentDigest": runbook.get("contentDigest"),
                "governedSkillRef": decision.get("governedSkillRef"),
            }
            binding_errors = [
                key
                for key, expected in expected_bindings.items()
                if handoff_value.get(key) != expected
            ]
            launch_v2 = {
                **launch_value,
                "protocolVersion": 2,
                "handoff": handoff_value,
            }
            launch_v2_errors = sorted(
                launch.iter_errors(launch_v2),
                key=lambda error: list(error.path),
            )
            if binding_errors or launch_v2_errors:
                failures += 1
                detail = (
                    f"authority pins differ at {', '.join(binding_errors)}"
                    if binding_errors
                    else launch_v2_errors[0].message
                )
                print(
                    f"FAIL  {handoff_path.relative_to(CONTRACT_DIR)} with "
                    f"{path.relative_to(CONTRACT_DIR)}: {detail}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"ok    {handoff_path.relative_to(CONTRACT_DIR)} with "
                    f"{path.relative_to(CONTRACT_DIR)} launch v2"
                )
            launch_v3 = {
                **launch_value,
                "protocolVersion": 3,
                "decision": preparation,
                "handoff": handoff_value,
            }
            launch_v3_errors = sorted(
                launch.iter_errors(launch_v3),
                key=lambda error: list(error.path),
            )
            if binding_errors or launch_v3_errors:
                failures += 1
                detail = (
                    f"authority pins differ at {', '.join(binding_errors)}"
                    if binding_errors
                    else launch_v3_errors[0].message
                )
                print(
                    f"FAIL  {handoff_path.relative_to(CONTRACT_DIR)} with "
                    f"{path.relative_to(CONTRACT_DIR)} launch v3: {detail}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"ok    {handoff_path.relative_to(CONTRACT_DIR)} with "
                    f"{path.relative_to(CONTRACT_DIR)} launch v3"
                )
        runtime = value.get("runtime", {})
        scope = value.get("approvedRunbook", {}).get("scope", {})
        refresh_value = {
            **scope,
            "refreshRequestId": "grq_019b1876-6f80-7000-8000-000000000042",
            "runtime": {
                "requestedAt": runtime.get("observedAt"),
                "capabilities": runtime.get("capabilities"),
                "locatorResolution": runtime.get("locatorResolution"),
                "applicationObservations": runtime.get("applicationObservations"),
            },
        }
        refresh_errors = sorted(
            refresh.iter_errors(refresh_value),
            key=lambda error: list(error.path),
        )
        if refresh_errors:
            failures += 1
            location = "/".join(str(part) for part in refresh_errors[0].path)
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} refresh at {location}: "
                f"{refresh_errors[0].message}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} refresh request")
        for forbidden, forbidden_value in (
            ("preconditions", runtime.get("preconditions")),
            ("businessObjectInputs", runtime.get("businessObjectInputs")),
        ):
            refresh_value["runtime"][forbidden] = forbidden_value
            if not list(refresh.iter_errors(refresh_value)):
                failures += 1
                print(
                    f"FAIL  {path.relative_to(CONTRACT_DIR)} refresh accepted "
                    f"caller-supplied {forbidden}",
                    file=sys.stderr,
                )
            else:
                print(
                    f"ok    {path.relative_to(CONTRACT_DIR)} refresh rejects "
                    f"caller-supplied {forbidden}"
                )
            del refresh_value["runtime"][forbidden]
        response_value = {
            "protocol": "dev.jazz.guided-execution-refresh",
            "protocolVersion": 2,
            "refreshRequestId": refresh_value["refreshRequestId"],
            "refreshRequestDigest": (
                "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
                "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
            ),
            "predecessorDecisionId": value["decision"]["decisionId"],
            "predecessorDecisionContentDigest": value["decision"]["contentDigest"],
            "decision": preparation,
        }
        response_errors = sorted(
            refresh_response.iter_errors(response_value),
            key=lambda error: list(error.path),
        )
        if response_errors:
            failures += 1
            location = "/".join(str(part) for part in response_errors[0].path)
            print(
                f"FAIL  {path.relative_to(CONTRACT_DIR)} refresh response at {location}: "
                f"{response_errors[0].message}",
                file=sys.stderr,
            )
        else:
            print(f"ok    {path.relative_to(CONTRACT_DIR)} refresh response")
    return int(failures > 0)


if __name__ == "__main__":
    sys.exit(main())
