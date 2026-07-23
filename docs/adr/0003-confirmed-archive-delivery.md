# ADR 0003 — Confirmed whole-archive delivery is the desktop default

- **Status:** Accepted
- **Date:** 2026-07-23
- **Tracks:** [keboola/jazz-desktop-client#9](https://github.com/keboola/jazz-desktop-client/issues/9)
- **Relates to:** [ADR 0001](0001-local-first-jazz-archive.md),
  [ADR 0002](0002-source-neutral-media-and-live-transport.md)

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
   schedules the next poll for that time. `failed_terminal` never exposes a Retry action.

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

`liveCompatibility` is an explicit opt-in migration policy. It starts the existing OTLP and
Keboola Files adapters, but those adapters project records already admitted by the canonical
journal and retain the same observation/artifact identities and CaptureCommit. The policy is frozen
for the duration of a capture so changing Settings cannot split one capture between modes.

A future canonical live stream may accelerate Capture Coach or provisional server views. It must use
the same records, IDs, and commit described by ADR 0002, remain optional, and never weaken offline
capture or confirmed-archive completion authority.

## UI and operational behavior

The local session view exposes commit/review/revision lineage and archive delivery separately. It
shows queued, uploading, server verification/processing, reconnect, retry backoff, terminal server
failure, cancellation, conflict, quarantine/rejection, and ready states. Retry and relaunch reuse
queue-owned bytes. Evidence playback is read-only; executing user input requires a separately
reviewed RunbookVersion and is not offered from a raw capture.

## Security boundary and consequences

Jazz Archive v1 deliberately has no local archive encryption. The managed Mac and its encrypted
disk are the assumed local boundary. Capture-time redaction and denylisting still apply before
persistence; transport and server storage have their own controls.

The enrollment bundle route is normalized and cross-bound to the live-verified project/stack, but
the current JSON bundle is not cryptographically signed or server-key pinned. Bundles must be moved
through the trusted admin surface until a separately versioned signed-envelope hardening is added.

The benefit is a portable, deterministic, consent-gated completion object that works offline and
can be retried, shared, replayed as evidence, and used to derive Process Memory, RunbookVersions, and
agentic skills. The costs are local storage use, explicit review, a second migration-only delivery
policy, and the need to operate durable ingest and token-rotation state machines.
