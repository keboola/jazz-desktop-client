#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["cryptography>=43,<47", "jsonschema>=4.23,<5"]
# ///
"""Produce a Jazz device bundle for Windows development and qualification.

Two profiles, because the server issues two shapes from one endpoint
(`POST /api/devices/{id}/token/start`, `apps/processor/src/jasnost_processor/api.py`):

  mvp  an UNSIGNED handoff stamped `enrollmentProfile: "mvp"`. This is what a Data App running
       the MVP runtime profile without a configured bundle issuer actually hands out today.
       Validated here against `contract/enrollment/schema/device-bundle-mvp-v1.schema.json`.

  v2   a SIGNED flattened Ed25519 JWS envelope, which a production composition with a
       secret-manager-fed signing key issues. Signed here with the RFC 8032 test key so the
       signed intake path can be exercised without that server configuration.

The v2 signing seed is RFC 8032 section 7.1 TEST 1 -- a published constant from the standard, not
a secret, and the same key the fixtures under `contract/enrollment/fixtures/` use. A build that
trusts key id `test-2026-07-rfc8032-1` will accept a bundle from anyone; never let it reach a
release artifact.

An unsigned bundle carries no cryptographic authority at all. It is only safe because the client
refuses to infer the mode from a missing signature, and then proves the credential against the
live Keboola `tokens/verify` response before storing anything. Emitting one here does not make it
trusted; the client still has to do that work.

Both profiles carry a live Storage API token, and `streamEndpoint` embeds the Data Stream source
secret in its URL path, so both are read from the environment and never echoed. Redirect stdout to
a file; do not paste the result into a chat, an issue or a log.

    export JAZZ_STREAM_ENDPOINT="$(op read 'op://Vault/Item/stream-endpoint')"
    export JAZZ_TOKEN="$(op read 'op://Vault/Item/storage-token')"
    uv run --script windows/Tools/make-device-bundle.py --profile mvp \
        --device win-dev-01 --project 8625 --stack https://connection.keboola.com \
        > bundle.json

Re-run notes for `--profile v2`: `bundleExpiresAt` is checked against the current time, and the
durable replay ledger refuses a *different* envelope at the same or a lower `--generation`. The
unsigned profile has neither field and no replay ledger, so it can be re-imported freely.

`--emit-trust-config` prints the trust configuration matching the v2 signing key, so a host build
and the envelope cannot disagree about issuer, audience or key id.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jsonschema
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

# windows/Tests/JazzEnrollmentSecurityTests/Fixtures/test-only-rfc8032-ed25519-key.json
TEST_SEED_HEX = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
TEST_KEY_ID = "test-2026-07-rfc8032-1"

# Defaults match windows/Tests/JazzEnrollmentSecurityTests/Fixtures/JazzEnrollmentTrust.json.
DEFAULT_ISSUER = "https://jazz.example.test"
DEFAULT_AUDIENCE = "jazz-desktop-client"
DEFAULT_REDEMPTION_ORIGIN = "https://native.example.test"

MVP_SCHEMA = "contract/enrollment/schema/device-bundle-mvp-v1.schema.json"

# SignedEnrollmentVerifier.PayloadKeys. The verifier requires exactly these, no more, no fewer.
V2_PAYLOAD_KEYS = frozenset({
    "schemaVersion", "kind", "bundleId", "generation", "issuer", "audience", "issuedAt",
    "bundleExpiresAt", "deviceId", "companyId", "areaId", "projectId", "stackURL",
    "archiveIngestURL", "token", "tokenId", "expiresAt", "tokenBucketScope",
    "sinkBucketId", "componentAccess", "streamSourceId", "streamEndpoint",
})


def b64u(raw: bytes) -> str:
    """Base64url without padding, as JWS requires."""
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def rfc3339(moment: datetime) -> str:
    return moment.isoformat().replace("+00:00", "Z")


def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--profile", choices=("mvp", "v2"),
        help="mvp = unsigned handoff (what the deployed server issues); v2 = signed envelope")
    parser.add_argument("--device", help="deviceId stamped on the bundle")
    parser.add_argument("--project", help="Keboola project id, digits only")
    parser.add_argument("--stack", help="Keboola stack base URL, e.g. https://connection.keboola.com")
    parser.add_argument("--company", default="default")
    parser.add_argument("--area", default="general")
    parser.add_argument("--token-id", default="123456")
    parser.add_argument("--stream-source-id", default="src-win-dev-01")
    parser.add_argument("--sink-bucket", default="in.c-otlp-win-dev-01")
    parser.add_argument(
        "--archive-ingest-url", default="https://jazz.invalid/api/archive-ingests",
        help="parsed but unused on Windows; archive delivery is out of scope")
    parser.add_argument("--token-valid-days", type=int, default=30)
    parser.add_argument(
        "--generation", type=int,
        help="v2 only; bump on every re-issue, the replay ledger requires a strictly newer value")
    parser.add_argument("--issuer", default=DEFAULT_ISSUER, help="v2 only")
    parser.add_argument("--audience", default=DEFAULT_AUDIENCE, help="v2 only")
    parser.add_argument("--bundle-valid-minutes", type=int, default=720, help="v2 only")
    parser.add_argument(
        "--emit-trust-config", action="store_true",
        help="print the trust configuration matching the v2 signing key and exit")
    return parser


def emit_trust_config(args: argparse.Namespace) -> int:
    print("TEST ONLY: this trusts the published RFC 8032 key. Never ship it.", file=sys.stderr)
    public = (Ed25519PrivateKey.from_private_bytes(bytes.fromhex(TEST_SEED_HEX))
              .public_key().public_bytes_raw())
    json.dump(
        {
            "JazzEnrollmentIssuer": args.issuer,
            "JazzEnrollmentAudience": args.audience,
            "JazzEnrollmentEd25519PublicKeys": {TEST_KEY_ID: b64u(public)},
            "JazzEnrollmentRedemptionOrigins": [DEFAULT_REDEMPTION_ORIGIN],
        },
        sys.stdout, indent=2)
    print()
    return 0


def common_fields(args: argparse.Namespace, endpoint: str, token: str,
                  now: datetime) -> dict[str, object]:
    return {
        "kind": "jazz-device-bundle",
        "deviceId": args.device,
        "companyId": args.company,
        "areaId": args.area,
        "projectId": str(args.project),
        "stackURL": args.stack,
        "archiveIngestURL": args.archive_ingest_url,
        "token": token,
        "tokenId": args.token_id,
        "expiresAt": rfc3339(now + timedelta(days=args.token_valid_days)),
        "componentAccess": [],
        "tokenBucketScope": "sink",
        "sinkBucketId": args.sink_bucket,
        "streamSourceId": args.stream_source_id,
        "streamEndpoint": endpoint,
    }


def emit_mvp(args: argparse.Namespace, endpoint: str, token: str, now: datetime) -> int:
    # enrollmentProfile is what makes the unsigned mode explicit. The client must require it and
    # must never infer this mode from a missing signature.
    bundle = {"enrollmentProfile": "mvp", **common_fields(args, endpoint, token, now)}

    schema_path = repo_root() / MVP_SCHEMA
    try:
        schema = json.loads(schema_path.read_text())
    except OSError as error:
        print(f"cannot read {MVP_SCHEMA}: {error}", file=sys.stderr)
        return 3
    try:
        jsonschema.validate(bundle, schema)
    except jsonschema.ValidationError as error:
        # Report the path only. The message can quote the offending value, which may be the token.
        print(f"the generated bundle does not satisfy {MVP_SCHEMA} at "
              f"{'/'.join(str(p) for p in error.absolute_path) or '<root>'}", file=sys.stderr)
        return 3

    json.dump(bundle, sys.stdout, indent=2)
    print()
    return 0


def emit_v2(args: argparse.Namespace, endpoint: str, token: str, now: datetime) -> int:
    if args.generation is None:
        print("--generation is required for --profile v2", file=sys.stderr)
        return 2

    payload = {
        "schemaVersion": 2,
        "bundleId": f"jdb_{os.urandom(16).hex()}",
        "generation": args.generation,
        "issuer": args.issuer,
        "audience": args.audience,
        "issuedAt": rfc3339(now),
        "bundleExpiresAt": rfc3339(now + timedelta(minutes=args.bundle_valid_minutes)),
        **common_fields(args, endpoint, token, now),
    }
    if set(payload) != V2_PAYLOAD_KEYS:
        print("payload key set no longer matches SignedEnrollmentVerifier.PayloadKeys; "
              "update this tool and the verifier together", file=sys.stderr)
        return 3

    protected = {"alg": "EdDSA", "kid": TEST_KEY_ID,
                 "typ": "application/jazz-device-bundle+jws"}
    protected_b64 = b64u(json.dumps(protected, separators=(",", ":"), sort_keys=True).encode())
    payload_b64 = b64u(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    signature = (Ed25519PrivateKey.from_private_bytes(bytes.fromhex(TEST_SEED_HEX))
                 .sign(f"{protected_b64}.{payload_b64}".encode()))

    json.dump({"protected": protected_b64, "payload": payload_b64,
               "signature": b64u(signature)}, sys.stdout, indent=2)
    print()
    return 0


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    if args.emit_trust_config:
        return emit_trust_config(args)

    missing = [name for name in ("profile", "device", "project", "stack")
               if getattr(args, name) is None]
    if missing:
        parser.error("missing required argument(s): " + ", ".join("--" + m for m in missing))
    if not str(args.project).isdigit():
        parser.error("--project must be digits only")

    endpoint = os.environ.get("JAZZ_STREAM_ENDPOINT")
    token = os.environ.get("JAZZ_TOKEN")
    if not endpoint or not token:
        print("set JAZZ_STREAM_ENDPOINT and JAZZ_TOKEN in the environment; this tool never "
              "accepts them as arguments, because a command line is not a secret channel",
              file=sys.stderr)
        return 2

    now = datetime.now(timezone.utc).replace(microsecond=0)
    if args.profile == "mvp":
        return emit_mvp(args, endpoint, token, now)
    return emit_v2(args, endpoint, token, now)


if __name__ == "__main__":
    raise SystemExit(main())
