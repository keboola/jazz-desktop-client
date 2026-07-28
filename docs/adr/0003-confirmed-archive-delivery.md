# ADR 0003 — Confirmed whole-archive delivery is the desktop default

- **Status:** Accepted
- **Date:** 2026-07-23
- **Tracks:** [keboola/jazz-desktop-client#9](https://github.com/keboola/jazz-desktop-client/issues/9)
- **Relates to:** [ADR 0001](0001-local-first-jazz-archive.md),
  [ADR 0002](0002-source-neutral-media-and-live-transport.md),
  [ADR 0004](0004-device-bound-enrollment-identity.md)

## Context

The direct OTLP/Keboola Files path made capture durability depend on several independent delivery
projections and allowed network activity before a user had reviewed the result. It also provided no
single immutable byte object for retry, exchange, deterministic ingest, evidence playback, or later
RunbookVersion/skill derivation.

Jazz needs capture to work offline, preserve richer source evidence than a live projection, and let
the user decide which exact completed revision leaves the machine. A later low-latency mode must be
possible without creating different identities or a second completion model.

## Decision

`confirmedArchive` is the default `JazzCaptureDeliveryPolicy`.

1. Capture writes canonical observations, artifacts, label/coach interactions, and producer gaps to
   the local `CaptureJournal`. Stop closes local input, drains registered producers, and persists one
   `CaptureCommit`; it does not wait for or require a network.
2. A committed archive remains a local draft until an archive-level human assertion says
   `confirm`. Before that exact assertion, the archive uploader may not create an intent, request an
   upload grant, or contact the archive control plane. `reject` never queues delivery.
3. Confirmation deterministically finalizes the revision and exports one unencrypted ZIP-compatible
   `.jazz-archive` into a dedicated durable whole-archive queue. The queue owns and verifies the
   exact `archiveId`, `originId`, `formatVersion`, `revision`, `contentDigest`, raw ZIP SHA-256,
   byte length, and bytes on every retry and relaunch.
4. Whole-archive delivery is independent of the older per-event and per-artifact spools. Its durable
   lifecycle is `queued → creatingIntent → uploading → finalizing → verifying/processing → ready`,
   with explicit `retryable`, `reconnectRequired`, `failed_terminal`, `rejected`, `quarantined`,
   `conflict`, and `cancelled` states. A server `failed_retryable` is never conflated with the
   terminal processing failure. Cancellation and every failure retain local bytes.
5. The control-plane adapter creates an intent, follows provider-neutral opaque direct-upload
   instructions in memory, submits an opaque receipt to finalize, and polls status. Signed URLs,
   headers, and grants are never persisted, interpreted as evidence, or synthesized by Core.
6. The server-issued scoped device token is read from Keychain only for a control-plane request and
   is sent only as `X-StorageApi-Token`. It is never serialized, logged, placed in a URL or process
   argument, sent as `Authorization`, or accompanied by `X-Kbc-User-Email`.
7. `ARCHIVE_TOKEN_EXPIRED`, a revoked token, or missing credentials moves the delivery to
   `reconnectRequired`. The package and its resume stage remain durable until an updated enrollment
   is imported.
8. A `failed_retryable` status may include `nextAttemptAt`. Desktop persists that watermark,
   suppresses automatic and manual retries before it, survives relaunch without losing it, and
   schedules the next poll for that time. When the server omits it, the desktop derives a bounded
   exponential delay with stable per-operation jitter from the durable `uploadOperationId`, then
   persists the selected absolute timestamp. Relaunch therefore preserves one archive's schedule
   while different archives do not synchronize their retries. `failed_terminal` never exposes a
   Retry action.
9. Queue schema v2 commits a caller-owned `uploadOperationId` (`uop-` plus a lowercase RFC 9562
   UUIDv7) before the first intent request. Intent, status, and finalize must echo that exact ID;
   retry and relaunch never remint it. Ambiguous active v1 records fail closed for reconciliation.
10. The only direct upload profile is bounded raw `http-put/v1`: HTTPS `PUT`, a bounded
    case-insensitively unique header map, and one mandatory receipt header. The only server-download
    profile is `http-get/v1`: an exact signed HTTPS `GET` URL with no provider headers. Redirects,
    alternate methods, multipart fallback, partial responses, and persisted grant material are
    rejected.
11. Server import commits `downloadOperationId` (`dop-` plus UUIDv7) to a non-secret local intent
    journal before authorization. Relaunch reuses it, including when the server renews an expired
    grant with a new authorization generation. Journal schema v2 binds the full non-secret signed
    delivery authority—issuer, audience, exact ingest endpoint, stack, project and
    Company/Area/device scope—plus ingest and import target. Token id, bundle id/generation and
    envelope digest may rotate only under that unchanged authority. It stores no signed URL or
    authorization credential and is removed only after byte-exact verified import. A schema-v1
    journal without that authority snapshot remains inspectable and explicitly abandonable, but
    cannot resume or reach authorization.
12. At most one server download may own the archive root. A stable cross-process file lease covers
    authorization, streaming, verified publication and journal completion; a second coordinator
    fails closed before network access. While an intent is pending, the UI permits only exact resume
    or deliberate abandonment, not a different server import. Abandonment first appends a
    non-secret audit record and removes only the acquisition journal—never an imported archive,
    snapshot, receipt or other evidence.
13. Queue, publication and intent transitions are power-loss durable. Before upload may read a
    credential or reach the network, the client commits the exact package, queue record and their
    directory entries while holding a stable cross-process queue lease. Import commits every
    package, provenance document, receipt and finalized snapshot—plus the containing archive-root
    entry—before a server-download journal may be removed. The macOS adapter requires
    `F_FULLFSYNC` for regular files and native `fsync` for directory entries; there is deliberately
    no weaker fallback. Any failure preserves canonical bytes and the recovery authority.
    After taking the download-operation lease, restart recovery may reap only exact UUIDv7-shaped
    temporary claims with the expected regular-file shape. A symlink, special file or unexpected
    child fails closed instead of being followed or deleted. A retry re-synchronizes an existing
    intent before network access; a matching abandonment audit is likewise re-synchronized before
    it may authorize journal removal. Native locking and durability are explicit platform
    dependencies supplied by the executable; portable capture-contract Core remains
    Foundation-only.
14. Archive control-plane response bodies are bounded before buffering, including responses without
    `Content-Length`: one MiB for control JSON and 64 KiB for the direct-PUT response. The signed
    archive GET remains streaming and is bounded by the grant's exact byte length and the client's
    archive-size limit. Caller cancellation atomically cancels the bounded URLSession task and
    completes its one pending continuation exactly once. Upload and download URLs reject ports
    outside `1...65535`.
15. An attempted queue-v1 upload with no durable operation ID remains a conflict until a user
    explicitly requests reconciliation. The client requires its previously pinned server authority,
    then makes one authenticated legacy intent request without an operation ID, validates the full
    immutable tuple and ingest ID, and atomically adopts only the valid UUIDv7 operation ID returned
    by the upgraded server. Lost intent, upload and finalize responses then continue through the
    ordinary v2 state machine.

## Enrollment and scope binding

An archive-enabled enrollment bundle contains one complete non-secret tuple: verified Keboola
`projectId`, exact normalized `stackURL`, Company, Area, device ID, canonical
`archiveIngestURL`, token ID, and expiry. The tuple is persisted as one Codable value; a new token
never inherits individual routing fields from an older enrollment. Bundle import verifies the token
on the exact bundle stack, rejects master tokens, and requires the verified owner project to equal
the bundle project before changing Keychain or routing state. Secret writes are rolled back if the
bundle transaction cannot complete.

The control-plane URL requires HTTPS, except for literal `localhost`, `127.0.0.1`, or `::1` in local
development. User information, query, fragment, whitespace/control characters, ambiguous path
segments, backslashes, encoded separators, and any path not ending in `/api/archive-ingests` are
rejected. A manually supplied raw token always clears/disables archive routing; it may be used only
with an explicitly supplied Stream endpoint in `liveCompatibility` mode.

The enrollment Area is authoritative for new captures. Their manifest uses
`enrolledDeviceIdentity = { namespace: "jazz.device", value: <bundle deviceId> }`, while the Mac
hostname remains only a source external identity. A non-General capture always claims the exact
enrolled Area; General is explicit. Legacy/pre-enrollment captures may omit the device claim, but a
queued package is checked locally against the enrollment's device and Area rules before any network
request or later scope binding. There is no implicit wildcard.

## Revision and correction policy

Review assertions are append-only. Before first finalization, correction may be followed by a new
confirmation of the same working revision. Once a revision is finalized, accepted, or queued, it is
never changed. A later correction forks the verified local evidence into a new draft with:

- a new globally unique `archiveId`;
- `revision = prior.revision + 1`;
- `supersedesArchiveId = prior.archiveId`;
- new CaptureCommit IDs carrying `supersedesCommitId` and `supersedesArchiveId`; and
- unchanged observation, artifact, capture, stream, actor, and source identities and evidence
  digests.

The corrected revision receives its own correction assertion and requires a separate explicit
confirmation before it can enter the delivery queue.

## Compatibility and future live delivery

`liveCompatibility` is an explicit opt-in migration policy. It starts OTLP and Keboola Files
adapters only after records have been admitted by the canonical journal. Before any OTLP request,
the client durably stores a byte-exact live sidecar containing the already persisted canonical
observation or artifact JCS, its SHA-256, and the same archive, origin, capture, stream, item, and
capture-time identities. Capture end requires the exact persisted `CaptureCommit`; its OTLP span
uses that same ID and canonical document. Missing, corrupt, mixed-lineage, reordered, or mutated
sidecars fail closed and remain retryable rather than falling back to legacy event truth.

When a liveCompatibility capture starts under signed enrollment, its EventSpool metadata pins the
exact non-secret archive route authority. The native Jazz live route is derived only as the
`/api/live-compatibility/v1/logs|traces` sibling of that exact signed
`/api/archive-ingests` route; no separately configured live URL is trusted. Before the first send,
the complete OTLP request body is persisted once. The batch or span becomes sent only after both
the legacy secret-bearing Data Stream endpoint and the authenticated Jazz route acknowledge those
same bytes. Each destination has a digest-bound durable acknowledgement, so a retry may repeat an
uncertain request but can never remap IDs or re-encode different bytes. The scoped token is read
from Keychain for each Jazz attempt and sent with the pinned device ID; neither token nor either
endpoint is logged. A manual legacy liveCompatibility configuration with no signed archive route
retains its original single-destination behavior.

The frozen OTLP mapping is a migration transport contract, not a second evidence model. Transport
epoch and delivery sequence are non-canonical. The server records database receive times
separately from original capture times and exposes live rows only as provisional diagnostics.
Only a READY, scope-matched, byte-verified Jazz Archive may become canonical. It deterministically
compares the exact accepted archive inventory with live IDs, order, JCS, and digests; the archive
wins every conflict. Rejected or quarantined archives never promote matching live rows. Typed,
bounded diagnostics distinguish live-only, archive-only, duplicate, late, mutated, extra,
reordered, and unsupported input. Retention is explicit and live receipt state is not a Process
Memory publication source.

The policy remains frozen for the duration of a capture so changing Settings cannot split one
capture between modes. `confirmedArchive` is unchanged and has no live network dependency. A future
source-neutral canonical live protocol may accelerate Capture Coach or meeting-source provisional
views. It must use the same records, IDs, and commit described by ADR 0002, remain optional, and
never weaken offline capture or confirmed-archive completion authority.

Operation-ID-aware desktop releases are activated only after every server replica advertises
archive transfer contract v2. During a mixed server rollout the desktop keeps the same durable
operation and treats only the exact old FastAPI “operation ID is an extra field” response—or a
missing operation echo on an otherwise valid status—as retryable. Ordinary delivery never falls
back to a request without the ID; the only exception is the explicit, authority-pinned queue-v1
reconciliation described above. All other validation failures remain fail-closed.

## UI and operational behavior

The local session view exposes commit/review/revision lineage and archive delivery separately. It
shows queued, uploading, server verification/processing, reconnect, retry backoff, terminal server
failure, cancellation, conflict, quarantine/rejection, and ready states. Retry and relaunch reuse
queue-owned bytes. Evidence playback is read-only; executing user input requires a separately
reviewed RunbookVersion and is not offered from a raw capture. A resumable v2 server acquisition is
visible after relaunch with exact Resume and Abandon actions; a legacy v1 journal without pinned
authority disables Resume and permits only deliberate abandonment. Starting another server import
stays disabled until the pending operation is resolved.

## Security boundary and consequences

Jazz Archive v1 deliberately has no local archive encryption. The managed Mac and its encrypted
disk are the assumed local boundary. Capture-time redaction and denylisting still apply before
persistence; transport and server storage have their own controls.

Input privacy is modality-aware rather than an accidental consequence of the input mechanism.
Secure AX fields and fields labelled as credentials are omitted for typing, selection, and paste.
Ordinary selected or pasted business text is retained after trimming and size bounding because it
is direct semantic evidence of the demonstrated process. Keyboard-derived text additionally masks
email addresses and long digit runs before persistence; `inputMasked` is set only when such a
replacement actually occurred. This asymmetry is deliberate defense in depth for ambient global
keystroke capture, not permission to expose a secure destination through selection or clipboard
evidence.

The enrollment tuple is carried in the flattened JWS v2 profile defined by the shared contract.
The client accepts only canonical protected/payload JSON, `alg = EdDSA`, the Jazz media type, and a
known `kid`; it verifies the Ed25519 signature against application-configured trust anchors before
admitting any generation, route, scope, or secret. Issuer, audience, validity interval, project,
stack/archive origins, Company, Area, device, token scope, and optional live route are one signed
atomic authority. Device-bound key continuity, redemption, rollback protection, and the
Secure Enclave production boundary are specified by ADR 0004; an unsigned legacy JSON bundle is
not a production enrollment path.

The benefit is a portable, deterministic, consent-gated completion object that works offline and
can be retried, shared, replayed as evidence, and used to derive Process Memory, RunbookVersions, and
agentic skills. The costs are local storage use, explicit review, a second migration-only delivery
policy, and the need to operate durable ingest and token-rotation state machines.
