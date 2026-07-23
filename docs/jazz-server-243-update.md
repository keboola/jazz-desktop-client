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
   Company/Area/device scope;
2. provider-neutral direct upload using only the opaque grant returned by the server;
3. `POST /api/archive-ingests/{ingestId}/finalize` with the opaque upload receipt; and
4. `GET /api/archive-ingests/{ingestId}` with the same scope for durable status.

Every response echoes the immutable tuple. The desktop treats a changed ingest ID, identity,
format version, digest, length, or scope as a conflict. Same tuple retries are idempotent.
Status responses distinguish `failed_terminal` from `failed_retryable`; only the retryable state may
carry `nextAttemptAt`, and the desktop durably preserves and obeys it across relaunch.

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

1. confirmed whole-archive upload, validation, immutable storage, and status endpoint;
2. archive-backed materialization plus OTLP parity reports for clients using explicit
   `liveCompatibility`;
3. archive-preferred reads for `READY` captures;
4. optional canonical live envelope stream with reconnect watermarks;
5. retire the compatibility projection only after parity, recovery, and rollback are proven.

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
- Authenticated tenant binding overrides package claims and prevents cross-tenant reads.
- A capture delivered by both OTLP and archive appears once in the public timeline; a parity report
  explains any mismatch.
- The current OTLP reader can be restored through configuration without re-importing data.

## Explicitly deferred

The first increment does not need process-instance inference, multi-actor handoff inference, live
transcription/coaching, meeting capture, executable replay or skill generation. Their schemas and
outputs must remain derived from the preserved canonical evidence so they can be added without
changing or rewriting the raw archive.
