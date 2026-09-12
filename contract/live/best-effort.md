# Best-effort v1 — inactive contract/authority extension

This is a required protocol boundary for future opt-in use, **not production activation or adoption
of additional loss**. Current archive confirmation, immutable delivery and liveCompatibility rules
remain unchanged. No current mode or settings entry selects this protocol.

## Permission and source identity

`enrollment/schema/best-effort-capability-v1.schema.json` is an **optional protected field** named
`bestEffortCapability` in the existing signed device-bundle-v2 payload. Absent means disabled; null,
unknown fields/versions, archive permission alone or an MVP/unsigned handoff do not authorize it.
The existing signature, out-of-band issuer/audience, expiry and monotonic enrollment-generation
checks still apply. The capability must name the bundle's dedicated `streamSourceId`, require sink
scope, and expire within the scoped credential lifetime. Old clients reject the new field, rather
than silently gaining a mode they cannot interpret. Import does not start capture.

The exact v1 choices are explicit: `ongoingTransmission:true`,
`lossPolicy:volatile-network-crash-overload-v1`, `lateInputPolicy:successorOnly`,
`fidelity:sampledActivity`, `coverage:unknown`. Issuing this field requires separately adopted
consent/policy; no enrollment UI/production issuer path begins emitting it in this slice.

An immutable `epoch` binds project, stack, Company/Area/device, source, signed bundle ID/generation,
origin/capture IDs, start and capability. Native validation derives the expected tuple from accepted
signed enrollment. Server authority reuses the existing native principal, signature verifier and
registry scope authority, and rechecks current device status, token, source and signed generation /
bundle digest. A receiver must supply **trusted transport/source mapping identity separately**;
client Company/device/source attributes are not that identity. Rotation/revocation closes the old
binding; no reinterpreting old backlog under a fresh permission.

## Provisional envelopes and OTLP

`live/schema/best-effort-v1.schema.json` admits `epoch`, `envelope` and `inputSelection` only.
Canonical bytes are RFC8785/I-JSON via existing archive codecs. One document is bounded to1MiB;
a reference input set to256 unique items /16MiB; the reference identity map to4096 bounded pins.
Exceeding bounds rejects, never evicts identity history to create apparent freshness/completeness.

An envelope pins the epoch's JCS SHA256 and reuses the exact observation/artifact projection item.
No `archiveId`, `CaptureCommit`, commit item, READY claim or exact global loss count is accepted.
The initial observation allowlist is `jazz.activity-event` / schema version1; new payload kinds need
coordinated readers, not shape guessing. Artifact metadata remains pending/unavailable/unknown;
metadata is not blob availability or a Files grant. Captured timestamps and clock uncertainty are
preserved, not used as warehouse cursors or proof of temporal causality.

OTLP body is `jazz.best_effort.provisional`; scope is `dev.jazz.best-effort`, without invented trace/span
IDs or legacy session attributes. The only attributes are `jazz.best_effort.version` (integer1),
`.epoch`, `.canonical` (exact envelope JCS) and `.digest`. Resource/client identity fields never
supply trusted scope. LiveCompatibility readers reject mixing this namespace; legacy session,
segment and analysis SQL excludes its markers instead of relabeling rows.

## Immutable identity and input selections

Same ID/same exact bytes is idempotent. Same ID/different bytes, another item in a used stream slot,
epoch-ID reassignment, reusing a capture for another epoch, or cross-mode identity aliasing is a
conflict. The portable reducer returns no modified prior state on conflict. Its shared identity keys
are `epoch:<id>`, `capture:<id>`, `item:<id>`, and `slot:<capture>:<stream>:<sequence>`. Values are exact
SHA256 pins. Production must transact these checks with retained bytes against its durable identity
namespace (including archived IDs), retain conflicting evidence for quarantine, and acknowledge only
after durable commit. The bounded reference reducer is **not** a new persistence service or an ACK.

A selection pins exact sorted item IDs and envelope digests, epoch digest, unknown coverage and
version. `selectionId = bes-<sha256(JCS(selection without selectionId))>`. Resolving it requires the
exact referenced envelopes; missing, altered or extra input cannot silently enter a frozen selection.
A later permitted input produces an explicit successor with `supersedesSelectionId`, never changes a
reviewed snapshot in place. Provenance references do not grant access to entire artifacts.

**v1 selections remain `authority:provisional`, `archiveReady:false`, `analysisEligibility:blocked`.**
They are immutable provenance, not an archive, human confirmation, media access or analysis grant.
Existing READY-only readers stay closed. A future scoped analysis-admission contract must validate
media access/bytes, payload/graph/privacy policy and authorized selection versions explicitly; neither
a valid signature nor an OTLP200 substitutes for those fences.

## Conformance

`generate_best_effort_fixtures.py --check` verifies the alternate-mode synthetic vectors and Swift
resource mirror; the prescribed `validate_live_transport.py` invokes it and schema-negative checks.
The fixture reuses canonical codec samples, not simultaneous archive and best-effort publications.
Swift and processor runners match exact OTLP, selection and identity-pin vectors. Signed golden03
uses the existing public RFC8032 **test-only** key. Processor mirrors are byte-identical to the pinned
native contract; legacy `jasnost.dev` schema URIs remain locally resolvable without rewriting archives.
No new HTTP route, durable ingest table, grant issuer, capture activation, or production resource is
created by these reference readers.
