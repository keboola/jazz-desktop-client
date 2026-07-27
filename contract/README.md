# Desktop capture contract

This directory defines the language-neutral protocol between desktop clients and Jazz's ingestion
and processor layers.

## Included interfaces

- schema/activity-event.schema.json — the raw event a client emits.
- schema/media-observation.schema.json — typed, source-neutral screen-share video, meeting audio,
  and transcript evidence with explicit clock uncertainty and participant-attribution status.
- schema/meeting-control-observation.schema.json — consent, participant presence, screen-share
  boundaries, and producer reconnect evidence from source-neutral meeting capture.
- schema/capture-capability-observation.schema.json — canonical authorization and availability
  transitions for native pointer, keyboard, Accessibility, screen, and audio capture. Permission
  revocation, temporary event-tap suppression, source failure, and recovery remain distinct.
- schema/area-registry.schema.json — the registry a client reads to offer guided process labels.
- conformance/fixtures/ — canonical ActivityEvents + SessionContext to OTLP logs/traces vectors.
  Swift, .NET, and the processor's Python mirror must deep-compare their output with these files.
- archive/schema/ — the canonical local-first Jazz archive envelope, session, label, artifact,
  capture-commit, inventory, review-assertion, and non-canonical delivery-state contracts.
- archive/fixtures/ — portable positive archive snapshots. `validate_archives.py` checks their
  schemas, references, raw-vs-derived boundary, content hashes, and inventory/content digest.
- live/schema/ and live/fixtures/ — a transport-neutral reconnect/ack conformance transcript.
  `validate_live_transport.py` proves duplicate delivery, sparse acknowledgements, late media, and
  reconnects converge on the exact same canonical records, artifacts, and `CaptureCommit`.
- execution/schema/guided-replay.schema.json — the exact server-owned guided replay decision and
  execution-receipt schema mirrored for desktop conformance. The fixture wrapper adds only local
  runtime confirmation and read-only evidence-playback vectors; `validate_schemas.py` validates
  every embedded decision and receipt against the normative mirror.
- execution/schema/guided-execution-launch.schema.json — the portable, exact server-to-desktop
  launch packet for one approved RunbookVersion and ProcessExecution. Version 2 adds one
  short-lived opaque capability bound to the exact decision, operator, enrolled target device,
  Company/Area/Process scope, governed skill, and native governance route. The golden handoff in
  `execution/handoff-fixtures/` is validated both alone and inside the full v2 launch packet.
- execution/schema/guided-execution-refresh.schema.json — the exact desktop-to-server payload for
  replacing an expired, unclaimed decision with newly observed native runtime facts. It
  intentionally cannot carry business-object authority; the server resolves current anchor heads.
  Before persistence, digesting, or transport, clients and servers sort capabilities by
  `(id, version)` and application observations by `(applicationId, observedVersion, environment)`;
  repeating a capability `id` is invalid. The same normalization trims non-empty text, renders
  timestamps as UTC with exactly six fractional digits (truncating further precision), and
  de-duplicates locator/application evidence by `(kind, ref)`, retaining the greatest confidence
  before sorting by that key. “Trim” means the exact Python 3.12 `str.strip()` whitespace scalar
  set: U+0009–U+000D, U+001C–U+001F, U+0020, U+0085, U+00A0, U+1680, U+2000–U+200A,
  U+2028–U+2029, U+202F, U+205F, and U+3000; internal whitespace is preserved.
- execution/schema/process-execution.schema.json — the server-issued occurrence, migration and
  terminal lifecycle contract shared by every replay host.
- enrollment/schema/ and enrollment/fixtures/ — the exact signed device-bundle v2 payload,
  flattened Ed25519 JWS envelope, and deterministic sink/archive-only conformance vectors. The
  fixture public key is test authority only; production clients obtain issuer, audience, key id,
  and public key from a code-signed or centrally managed bootstrap channel, never from a bundle.
- enrollment/device-bound/fixtures/, enrollment/device-bound/http-fixtures/, and the
  device-claim-v1, sealed-device-bundle-v1, and device-redemption-*-v1 schemas — the deployed
  native device-bound redemption boundary. The server persists only the short-lived bearer's
  digest; a native client may retain the exact bearer only in its credential store while the
  operation is pending. One canonical claim binds it atomically to distinct 65-byte
  uncompressed P-256 ES256 proof and ECDH wrapping public keys. Claim proofs use raw 64-byte
  low-S `r || s`. Exact signed-bundle bytes are sealed once with ephemeral P-256 ECDH,
  HKDF-SHA256 and AES-256-GCM, then the exact ciphertext is the sole retry value. The authenticated
  context binds bootstrap, claim, device, both RFC 7638 key thumbprints, bundle id, generation,
  digest and reveal window. This protects enrollment credentials in transit and binds redemption
  to one device key; it does not encrypt Jazz Archives.

The fixtures are committed expected output, not a serialization library. A mapping change is a
cross-repository change: update this contract and the processor mirror together, pin the resulting
desktop-client commit in the processor submodule, and make every runner green.

Guided replay decisions and receipts are admitted from their original JSON envelope. The native
model must prove decode/re-encode semantic equality before displaying an instruction or appending a
receipt; schema drift therefore fails closed instead of silently dropping server-owned runtime,
anchor, approval, idempotency, branching, result, or completion-proof evidence.

Signed device enrollment v2 is an all-or-nothing authority tuple: exact normalized Keboola stack
and verified project, Company, Area, device, canonical archive control-plane URL, token id, expiry,
bucket/component scope, and optional live endpoint are protected by one Ed25519 signature. Disabled
fields remain explicit `null`, so import cannot inherit stale routing. The scoped token and optional
stream endpoint remain Keychain-only. Each device persists its highest accepted generation,
bundle id, and envelope digest, while one durable global history reserves every accepted bundle id
to its originating device and exact envelope digest. Lower generations fail as rollback; the same
generation is idempotent only for the same id and bytes, and a historical id can never be rebound.

The archive and stream contracts are deliberately different layers. An archive record is a generic,
transport-neutral observation envelope identified by globally unique `observationId`, `originId`,
`captureId`, and `streamId` plus a stream-local `streamSequence`.
`(recordType, payloadSchema, schemaVersion)` must resolve through both the manifest's `contracts`
array and an importer-owned local allowlist; schema URIs are identifiers and are never fetched.
The current `ActivityEvent` is one v1 payload specialization. Meeting screen-share, audio, and
transcript evidence uses `jazz.media-observation`; it MUST NOT be disguised as an `ActivityEvent`
with missing native fields. Downstream evidence references point to the canonical `observationId`,
`artifactId`, or transcript span. A consumer may project those records into a timeline, but it must
not reclassify meeting media as native Accessibility, pointer, keyboard, or direct-input evidence.
Native capture availability uses `jazz.capture-capability-observation`; a Secure Input or event-tap
timeout is temporary suppression while authorization remains granted, not a fabricated TCC
revocation. Repeated unchanged polls are silent. Every emitted transition occupies a canonical
stream coordinate before archive commit.
`legacyCorrelation` preserves its session/event/sequence mapping without making that legacy shape
the archive identity. Optional platform-neutral interaction context supports replay and later agent
skill derivation without pretending that a lossy OTLP projection contains the same evidence.

Labels are immutable evidence intervals, not mutable process rows. When a user later reopens the
same declared process step, `archive-label.lineage` keeps a linear chain: the first segment is the
`baselineLabelId`, and each later segment names exactly one immediately preceding
`resumesLabelId`. Validation requires the same semantic declaration, an earlier predecessor on the
same canonical stream, and one successor per segment. This preserves interruption and resumption
without inventing cross-stream causality, merging intervals, or resetting Capture Coach history.

`originId` is a globally unique, offline-minted installation/producer identity. `originScope` and
`enrolledDeviceIdentity` are untrusted provenance claims. They MUST NOT select a tenant or grant
authorization. Jazz binds an import to the authoritative tenant/project from its authenticated
ingest context and may return that separately as `serverIngestBinding` in non-canonical delivery
state.

OTLP, Keboola Files, archive upload, and live record streaming are versioned delivery projections.
Their trace/span/file/receipt ids, authoritative ingest binding, and retry state live only under the
working archive's non-portable `sync/` state. Network failure must retain canonical records and
artifacts; transport acknowledgement never becomes evidence.

The desktop default is confirmed whole-archive delivery. Committed evidence is fully usable offline,
and no archive control-plane request is permitted before an archive-level confirmation assertion.
Rejection never queues delivery. The direct OTLP/Keboola Files projection exists only under the
explicit `liveCompatibility` migration policy and must retain the same canonical identities and
CaptureCommit. That opt-in covers every canonical archive observation admitted during the capture,
including capability transitions and auditable Capture Coach interactions, plus canonical artifact
metadata and the final commit. It does not by itself authorize raw microphone PCM or live AI
analysis: the Capture Coach channel has a separate explicit consent control.

`archiveId` is an opaque identity minted before capture is finalized. A finalized package adds a
separate `contentDigest = sha256(JCS(manifest without contentDigest))`, where JCS is
[RFC 8785](https://www.rfc-editor.org/rfc/rfc8785). The manifest includes the JCS inventory digest,
so this binds archive metadata and every inventoried byte. The same id plus the same digest is an
idempotent import; the same id with a different digest is a conflict to quarantine. Reviewed or
re-finalized packages mint a new archive id and may point to the prior immutable package through
`supersedesArchiveId`.

Every integer anywhere in canonical archive JSON, including extensible payloads, must remain in the
I-JSON interoperable range `[-9007199254740991, 9007199254740991]`. Writers and importers reject
values outside that range before hashing, so two distinct integer values can never collapse to the
same IEEE-754/JCS digest.

A closed capture references a `CaptureCommit` from both its session and the finalized manifest. The
commit records revision, end time, every stream's first/last/count, explicit missing sequence ranges,
and two closure hashes:

- `orderedObservationDigest` hashes lines
  `<streamId>:<streamSequence>:<observationId>:<sha256(JCS(record))>\n`, ordered by stream id then
  sequence.
- `artifactSetDigest` hashes lines `<artifactId>:<content.sha256>\n`, ordered by artifact id; an empty
  set hashes empty bytes.

This proves both identity/order and envelope content. The commit is transport-neutral and may be
sent unchanged after live record streaming. Monotonic event time carries clock, clock-domain, and
boot identity so records from different clocks are not ordered as if they shared a domain. A media
interval also carries explicit uncertainty. Temporal overlap or adjacency is not causal evidence;
handoffs and process causality remain provenance-bearing derived assertions.

## Live delivery invariants

The live contract is optional acceleration, not a local bridge or service and not a second evidence
model. A connection epoch may deliver observations and artifact documents at least once and out of
order. The receiver keys immutable content by canonical ID plus JCS digest, acknowledges the next
contiguous sequence and any sparse accepted sequences per stream, and resumes only from the exact
last acknowledged state. Artifact metadata does not acknowledge its blob: `artifactIds` enter the
resume state only after the trusted receiver-side blob store reports durable bytes whose SHA-256
and byte length match the canonical artifact. Same ID/same digest is idempotent; same ID/different
digest, a reused stream slot, an unverified blob claim, or a reconnect watermark mismatch fails
closed. A commit remains incomplete until all records, artifact metadata, and verified durable
blobs it closes are present, then the byte-identical archive `CaptureCommit` becomes the completion
authority.

### Capture Coach advisory channel

`live/schema/capture-coach-live.schema.json` defines the optional, explicit-consent Capture Coach
channel. It is an advisory projection of evidence that is already canonical locally; it never owns
capture, archive commit, or action truth. Capture, label close, Coach actions, and archive commit
wait only for local durable archive or exact-byte spool writes. HTTP delivery and prompt polling run
outside those barriers. A disabled or unavailable channel therefore has no effect on offline
capture.

The same-origin endpoints derived from the signed archive-ingest authority are:

- `POST /api/capture-coach/live/messages`
- `GET /api/capture-coach/live/prompts/next`
- `POST /api/capture-coach/live/receipts`

Every message and receipt is JCS-encoded once, written durably before delivery, and retried as the
same bytes until a strict persisted acknowledgement echoes its identifier and content digest.
HTTP 409, malformed acknowledgements, local corruption, and scope/protocol mismatches suspend the
affected route partition without deleting queued bytes. Signed route authority selects a durable
partition; credential and bundle-audit rotation within the same authority does not. Global
write-once identity fences still reject reuse of a `ccm-*` or `ccr-*` identifier with different
bytes across all partitions.

Prompt polling is never an unscoped “next” request. The GET selector contains exactly
`companyId`, `areaId`, `processId`, `deviceId`, `captureId`, and `labelId`; a response is accepted
only when its signed authority and all six lineage fields match. A durable prompt intent precedes
canonical interaction recording. Interrupted recovery is deterministic: an intent with no
completed presentation becomes one `interrupted_capture` suppression, an already-recorded
`received` interaction is followed by that suppression, and a durable `shown` decision is simply
reprojected. Lost-ACK redelivery repairs the same receipt bytes without presenting the prompt
again.

Pending queue entries retain their exact canonical bytes. A terminal ACK first publishes and
fsyncs a compact tombstone containing the logical identifier, raw-byte SHA-256, byte length, and
document content digest; only then may it remove the pending bytes. Tombstones are retained for the
installation lifetime rather than time-pruned, so a relaunch still accepts an exact replay as a
no-op and rejects the same identifier with changed bytes. Full payload retention is therefore
bounded to pending delivery, while each acknowledged identity has a fixed-size collision record.
A one-time legacy migration fsyncs each capture-scoped head before replacing its old full ACK
documents and then writes a durable directory-format marker. Steady-state watermark recovery uses
that compact head plus pending bytes without scanning the lifetime ACK history. The head is retired
only after the canonical local `CaptureCommit` succeeds, never merely because delivery is suspended
or credentials rotate.

For native desktop capture, `producerId` is the archive session's `sourceId`, not the long-lived
device id. Message watermarks are cumulative per label and include every observed stream and
transcript coordinate for that label. Raw live PCM is optional and bounded; its stream is
label-scoped, starts at sequence zero for each label, and uses millisecond offsets derived from PCM
frame counts relative to that label's microphone start. The canonical narration artifact's
`captureInterval` remains the wall-clock replay authority. A final archive `CaptureCommit`
watermark supersedes partial advisory heads only after canonical local commit.

## Portable container rules

A finalized export is a ZIP container with the `.jazz-archive` suffix and `manifest.json` plus
`inventory.json` at its root. These are protocol requirements, not implementation suggestions:

- ZIP entry names MUST be UTF-8, relative, slash-separated, and in the v1 portable ASCII path
  subset defined by `relativePath`. Absolute paths, backslashes, NUL, empty segments, `.`/`..`
  segments, and normalization/case-colliding duplicate names MUST be rejected before extraction.
- Duplicate ZIP entries, encrypted entries, symlinks, hard links, devices, sockets, FIFOs, and other
  non-regular entries MUST be rejected. Local/ZIP encryption is not part of v1; storage and transit
  security belong below the archive contract.
- An importer MUST inspect the central directory and the v1 header/layout profile before extraction
  and enforce finite configured limits for entry count, per-entry bytes, total bytes, and structured
  data. Jazz MUST publish its ingest limits; exceeding any limit rejects the package atomically.
- Every portable regular file except `manifest.json` and `inventory.json` MUST appear exactly once
  in the inventory with byte length and raw-byte SHA-256. Unlisted files and missing entries reject
  the package. Blob filenames equal their raw-byte SHA-256.
- `sync/` is working-state only: it is excluded from inventory and MUST NOT be included in a final
  `.jazz-archive` export. Import never trusts client delivery state.

Receivers validate paths and limits while still inside a staging directory, then validate schemas,
JCS digests, capture commits, references, and authorization binding before making an import visible.

### Canonical desktop ZIP32 profile

`formatVersion: 1` has exactly one byte-level container profile. Every v1 producer MUST emit it and
every v1 receiver, including Jazz server ingest, MUST reject a package outside it before reading
entry bodies. A receiver MUST NOT silently decompress, normalize, or repack a non-canonical package
as v1 because the original package SHA-256, byte length, and bytes are durable delivery provenance.

- The container is single-disk ZIP32. ZIP64 records and sentinels, prefixes, gaps, data descriptors,
  archive/entry comments, extra fields, digital signatures, and trailing bytes are forbidden. The
  EOCD is the final 22 bytes.
- Local headers use `versionNeeded = 20`, flags `0x0800` (UTF-8 only), method `0` (stored), DOS time
  `0`, and DOS date `0x0021`. Central headers additionally use `versionMadeBy = 0x0314`, disk start
  and internal attributes `0`, and external attributes `0100644 << 16`.
- Every entry is a regular file; explicit directory entries and every link or special-file type are
  forbidden. Compressed and uncompressed sizes are equal. Local and central names, CRC32, sizes,
  method, flags, and fixed timestamp fields match exactly.
- Portable ASCII file paths are emitted exactly once in strictly ascending UTF-8 byte order. Local
  entries start at byte zero, use that same order, are contiguous, and end exactly where the central
  directory begins.

This stored-only profile is an intentional Foundation-compatible trust boundary, not a missing
decompressor. Supporting DEFLATE, ZIP64, or another layout requires a separately reviewed container
profile and archive format version; it is not a permissive extension of v1.

`archive/container/fixtures/01-canonical-v1.jazz-archive` is the byte-exact conformance vector. It
packages `archive/fixtures/02-labeled-narration` while excluding its non-portable `sync/` working
state. Its `.sha256` sidecar is normative: every writer must reproduce those exact bytes and every
receiver must accept them without normalization. `archive/container/generate_fixtures.py --check`
verifies both files.

The desktop defaults match the published server envelope: 2 GiB package bytes, 10,000 entries,
512 MiB per entry, 4 GiB expanded total, 256 MiB structured total, 32 MiB per JSON document,
4 MiB per NDJSON line, 250,000 NDJSON records, and 1,024 UTF-8 bytes per path.

Import acquisition metadata is local and non-canonical. The exact package SHA-256 and byte length
form its package ID; each successful file selection appends a separate receipt containing import
time, importer external identity, importing installation origin/source, and device label. Receipts
never alter `manifest.json`, its captured actors, `contentDigest`, or the exact package bytes.

## Validation

```bash
uv run --no-project --with jsonschema python contract/validate_schemas.py
uv run --no-project --with jsonschema python contract/archive/validate_archives.py
uv run --no-project --with jsonschema python contract/live/validate_live_transport.py
uv run --no-project --with jsonschema python contract/live/validate_capture_coach_live.py
uv run --no-project --with jsonschema python contract/live/generate_capture_coach_fixtures.py --check
python3 contract/archive/container/generate_fixtures.py --check
```
