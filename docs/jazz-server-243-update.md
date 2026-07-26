# Jazz Archive server counterpart (`keboola/jazz#243`)

## Outcome

Add a durable Jazz Archive ingest path that is the server counterpart of the desktop capture
contract. A finalized `.jazz-archive` is the completion authority for a capture; the existing OTLP
projection remains an explicit live/provisional compatibility path during migration. A later live protocol
must carry the same `ObservationEnvelope` records and `CaptureCommit`, not introduce a second event
model.

The normative client-side contract lives under `contract/archive/` in
`keboola/jazz-desktop-client`. The server must pin an explicit supported contract release or commit
and mirror its schemas and golden fixtures. Schema identifiers are identifiers only: ingest must
resolve the declared `(recordType, payloadSchema, schemaVersion)` through a server-owned local
allowlist and must never fetch schemas from archive-supplied URLs.

## Ingest lifecycle

Persist a restartable state machine before starting validation:

`created → uploaded → validating → validated → importing → ready`

Terminal integrity/policy failures go to `rejected` or `quarantined`. A non-retryable worker/import
failure is `failed_terminal`; an operational failure is `failed_retryable` with a persisted
checkpoint and optional RFC 3339 `nextAttemptAt`. The latter is a server-owned backoff watermark:
clients must not retry before it. Readers may see the archive-backed projection only after atomic
publication of `ready`.

The native control-plane surface is:

1. `POST /api/archive-ingests/intents` with the immutable archive tuple (`archiveId`, `originId`,
   `formatVersion`, `revision`, logical `contentDigest`, raw ZIP SHA-256, byte length) and exact
   Company/Area/device scope plus the caller-durable `uploadOperationId`;
2. the same intent route without `uploadOperationId` only for an explicit migration of an ambiguous
   queue-v1 record, authenticated against the previously pinned authority; it returns a stable v2
   operation ID and the exact immutable tuple, and exact retries return that same operation;
3. provider-neutral bounded raw `http-put/v1` using only the in-memory opaque grant returned by the
   server;
4. `POST /api/archive-ingests/{ingestId}/finalize` with the same upload operation ID and opaque
   upload receipt;
5. `GET /api/archive-ingests/{ingestId}` with the same scope for durable status; and
6. `POST /api/archive-ingests/{ingestId}/download-grants` with caller-durable
   `downloadOperationId`, followed by strict `http-get/v1`.

Every response echoes the immutable tuple. The desktop treats a changed ingest ID, identity,
format version, digest, length, scope, or operation ID as a conflict. Same tuple retries are
idempotent. Upload operation IDs bind one queue record to one ingest. Download operation IDs bind
one signed delivery authority (issuer, audience, exact ingest endpoint, stack and project), ingest,
authenticated Company/Area/device scope, import target and exact accepted byte identity; an expired
short-lived grant appends a new authorization generation under the same operation rather than
wedging relaunch recovery. Desktop persists that non-secret authority snapshot before the first
authorization call. Token or bundle generation may rotate under an unchanged authority, but an
issuer, audience, endpoint, stack, project or scope change fails closed before a credential read or
network request. Legacy desktop download journals that predate the full authority snapshot are
inspectable and explicitly abandonable only; they are never resumed.
Status responses distinguish `failed_terminal` from `failed_retryable`; only the retryable state may
carry `nextAttemptAt`, and the desktop durably preserves and obeys it across relaunch.

The operation-ID-less migration request is not a general compatibility fallback. It may create or
recover only the ingest selected by the authenticated tenant plus the complete immutable archive
tuple, must allocate its v2 operation ID before side effects, and must be idempotent across a lost
response. A tuple or authority mismatch is a non-enumerating conflict. Once the desktop adopts the
returned operation ID, every subsequent intent and finalize request carries it, while every status
response must echo it for exact client-side validation.

Control JSON responses must fit within one MiB and the direct-PUT response within 64 KiB; desktop
enforces both limits while bytes arrive, whether or not `Content-Length` is present. Signed archive
GETs remain streamed but may produce only the grant's exact byte length, within the negotiated
archive maximum. Transfer-profile URLs use HTTPS and a port in `1...65535`.

All control-plane calls authenticate only through `X-StorageApi-Token`. The server live-verifies
that scoped token, binds its owner project to the registry, and returns stable machine-readable
errors. `ARCHIVE_TOKEN_EXPIRED` is a reconnect/rotation state, not data loss. Neither
`Authorization` nor `X-Kbc-User-Email` is part of this protocol.

Ingest must:

1. Bind the request to the authenticated tenant/project and server registry Company, Area, and
   device. `originScope` and enrolled-device fields in the package are provenance claims and never
   authorization, but any present `enrolledDeviceIdentity.value` must equal the authenticated
   device. A missing Area claim is accepted only for explicit General; every non-General claim must
   exactly match the authorized Area. Process IDs must belong to that Area.
2. Apply bounded safe-ZIP rules before expansion: no encryption, duplicate paths, traversal,
   absolute paths, symlinks or special files; reject case-fold path collisions and enforce limits on
   entry count, per-entry size, total expanded size and compression ratio.
3. Validate JSON with strict I-JSON parsing, local JSON Schemas and the payload allowlist.
4. Verify inventory byte lengths and SHA-256 hashes, inventory JCS digest, manifest JCS digest,
   capture-commit digest, ordered observation digest, artifact-set digest, references, stream
   ranges and declared gaps.
5. Store the original finalized package immutably before building projections.
6. Register storage-neutral artifacts and materialize capture/session and observation read models.
7. Preserve raw evidence separately from transcripts, process instances, handoffs, replay plans and
   skills, which are versioned derived records with provenance.

The archive is intentionally not locally encrypted. Transport and server-side storage controls
remain server responsibilities; archive encryption is not part of this contract.

## Identity and idempotency

- Same `archiveId` plus the same `contentDigest`: idempotent success returning the existing ingest.
- Same `archiveId` plus a different digest: quarantine as an integrity conflict; never overwrite.
- Same `uploadOperationId` plus another archive, or the same archive plus another operation:
  non-enumerating conflict before object-store work.
- An operation-ID-less queue-v1 reconciliation with the same authenticated immutable tuple:
  idempotently return the one server-owned v2 operation ID and ingest. A different tuple or
  authority must not discover, replace or mint an identity for the existing operation.
- Same `downloadOperationId` plus another ingest, reader/device scope, or accepted object:
  non-enumerating conflict before grant issuance. An exact retry recovers the current authorization
  or appends a new generation after expiry while retaining prior audit rows.
- Same `observationId` plus the same canonical record digest: idempotent replay.
- Same `observationId` plus a different digest: quarantine the conflict; neither value silently
  wins.
- A changed capture requires an increasing revision and explicit lineage (`supersedesArchiveId` or
  the corresponding commit lineage). Reusing a capture ID without valid lineage is a conflict.
- Stream sequence is an ordering/reconciliation key, not entity identity. Gaps remain explicit
  quality facts.

Capture, archive, process-instance and actor identity must not be conflated. One process instance may
span several captures, people and devices; joins and handoffs are derived from business-object
intersections, declarations and reviewed inference.

## Read compatibility and rollout

During dual delivery, the composite reader chooses exactly one source for a completed capture:

1. a `ready` archive projection when archive-preferred mode is enabled;
2. otherwise the existing OTLP projection.

It must never concatenate both. Shadow comparison may reconcile observation IDs, counts, timestamps,
artifacts and commit digests without publishing duplicates. Rollout needs a per-tenant/configuration
switch that immediately restores the OTLP reader.

Rollout order:

1. deploy operation-ID-aware server contract v2 to every replica and prove each replica's
   readiness response before distributing the strict desktop;
2. confirmed whole-archive upload, validation, immutable storage, status, and exact download
   endpoint;
3. archive-backed materialization plus OTLP parity reports for clients using explicit
   `liveCompatibility`;
4. archive-preferred reads for `READY` captures;
5. optional canonical live envelope stream with reconnect watermarks;
6. retire the compatibility projection only after parity, recovery, and rollback are proven.

## Future live counterpart

The future stream begins with an authenticated capture-context registration containing `originId`,
capture/stream declarations and actor/source definitions. Every observation carries `originId`,
`captureId`, `streamId`, `streamSequence` and stable `observationId`. The server acknowledges the
highest contiguous accepted sequence per stream. Reconnect resumes after that watermark; artifacts
may resolve asynchronously. `CaptureCommit` closes and reconciles the same IDs and digests used by
archive import.

This protocol is optional acceleration for coaching and provisional timelines. Network loss must
not stop capture, and a timeline is provisional until its commit is satisfied.

## Acceptance criteria for the first server increment

- A valid desktop golden archive imports to `ready` and can be imported repeatedly without
  duplicate canonical records.
- Every mutated golden case in the contract suite is rejected for the expected reason, including
  unknown payload tuple/version, digest tampering, dangling references, sequence/commit mismatch,
  path traversal, duplicate/case-fold-colliding paths and ID reuse with different content.
- Restarting a worker at any ingest checkpoint completes without duplicating records or losing the
  immutable package.
- Lost legacy intent, upload and finalize responses can be reconciled once through the authenticated
  queue-v1 path; the returned operation ID is stable, tuple-bound and used by every later request.
- Oversized control and PUT responses—including chunked responses—are rejected before unbounded
  buffering; signed GET remains byte-exact streaming.
- Authenticated tenant binding overrides package claims and prevents cross-tenant reads.
- A capture delivered by both OTLP and archive appears once in the public timeline; a parity report
  explains any mismatch.
- The current OTLP reader can be restored through configuration without re-importing data.

## Follow-on layers built above the ingest

The first ingest increment deliberately did not make process-instance inference, multi-actor
handoffs, live coaching, meeting capture, guided replay, or skill generation part of archive
acceptance. That separation remains normative: a valid canonical archive never depends on a
derived AI or governance result.

The follow-on contracts now layer those capabilities over the immutable evidence:

- Capture Coach keeps transcript/evaluation/prompt/answer provenance separate and advisory;
- source-neutral meeting capture commits the same observation and artifact model;
- business-object anchors and reviewed intersections connect captures without rewriting them;
- Process Memory and process findings remain temporal, conflict-aware projections;
- immutable `RunbookVersion` and server-issued `ProcessExecution` pin guided replay to reviewed
  evidence, policy, operator, device, and business-object assertions; and
- governed skills are compiled artifacts with their own digest and approval lineage.

Every production desktop launch is bound to one exact server-authorized operator and one enrolled
device. A reviewed Alice → Bob process handoff is supported by recording Bob as the exact successor,
preparing a new READY decision under Bob's authenticated policy context, and issuing Bob a separate
device-bound launch capability. An already issued Alice launch is deliberately not transferable or
locally reassignable. A locally entered email is only a fail-closed consistency assertion; it is not
proof of a person or physical Mac and must never be edited to simulate delegation.

Richer multi-person and cross-process topology stays append-only through reviewed intersections
and transitions. Automatic OS action execution is not implied by guided replay: the shipped path is
an evidence-backed assistant with claim/start/receipt/reconciliation governance.
