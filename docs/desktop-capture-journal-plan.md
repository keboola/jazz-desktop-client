# Desktop CaptureJournal implementation plan

## Implemented invariant

`CaptureJournal` is now the canonical capture writer. It durably claims archive, capture, stream,
source, and actor identity before enabling the event tap; every producer reserves work before
asynchronous enrichment; and Stop drains reservations to evidence or explicit gaps before writing
the CaptureCommit. Screenshot and narration bytes enter the archive before any optional delivery
projection. ADR 0003 makes confirmed whole-archive delivery the default and keeps OTLP/Files behind
the explicit `liveCompatibility` policy.

## Required lifecycle

`idle -> starting -> recording -> closing_input -> draining -> committed`

- `starting`: mint and exclusively claim archive, origin, capture and stream identities; persist
  manifest/session/context before enabling the event tap.
- `recording`: each producer registers durable pending work before starting asynchronous work.
- `closing_input`: stop the event tap and application observer; no new producer work is admitted.
- `draining`: every registered item resolves to canonical observation/artifact bytes or to an
  explicit quality gap. The drain is bounded and independent of network availability.
- `committed`: append `session_end`, write `CaptureCommit`, close the journal and reject all late
  writes. Recovery or user correction creates a new archive revision.

`start()` must expose a starting state (or become async) so capture cannot begin before the durable
claim exists. A second capture cannot reuse state while the previous one is draining.

## Single-writer journal

Introduce a `CaptureJournal` actor in `JasnostCaptureCore` as the only writer of canonical capture
state. It owns:

- the archive manifest, capture context and stream registrations;
- observation-envelope append and ordered stream sequence allocation;
- an on-disk pending-producer ledger;
- atomic artifact/blob ingest and content hashing;
- labels and narration segment boundaries;
- the finalization barrier, explicit gaps and `CaptureCommit`;
- crash recovery of open or draining captures; and
- a transport-neutral delivery ledger outside canonical archive content.

Potentially long media never enters the journal as a whole in-memory value. The capture executable
prepares a journal-owned writable claim before the OS recorder starts, records directly into that
path, and atomically seals it after the writer closes. Ingest accepts the resulting capability, not
an arbitrary mutable temporary-file URL. SHA-256, staging copies, crash-recovery comparisons,
inventory verification, finalization, and large-media upload all operate in bounded chunks. The
small `Data` convenience remains available for already-compressed screenshots.

The event spool, narration spool and screenshot staging must become adapters/read models of this
journal or be retired. Two independent writers must not try to keep OTLP and archive state in sync.

## Producer rules

- **Input/Accessibility:** allocate one stream position and persist pending work before dispatching
  AX enrichment. Completion appends the enriched observation; timeout records the reserved sequence
  as a gap.
- **Screenshot:** capture and atomically ingest bytes into the journal before any Files prepare or
  upload. The observation references the storage-neutral `artifactId`; Keboola file ID is delivery
  metadata, not canonical identity.
- **Narration:** atomically ingest the closed audio segment and append its observation immediately.
  Transcription and Files upload happen later. No canonical record depends on network success.
- **Labels/controller events:** append synchronously through the journal and use the same stream
  ordering/identity rules.

Every work item carries the capture generation it belongs to. Once committed, completion callbacks
cannot append behind the commit; they can only be ignored with an existing declared gap or create an
explicit recovery revision.

## Stable identity

Persist a non-secret installation/origin identity once per installed client. Keep these concepts
separate:

- opaque `originId` for globally unique offline provenance;
- enrolled device identity claim;
- archive-scoped actor ID plus declared external person/email identity;
- device/source IDs and producer version/build; and
- per-capture archive, capture, stream, observation and artifact IDs.

All newly minted IDs use UUIDv7 and are claimed with exclusive, no-overwrite filesystem creation.
The server remains responsible for authenticated tenant binding.

## Review and export

After commit, the user may review, annotate or reject material. A correction never mutates the
committed evidence package in place: it creates a new immutable archive revision with
`supersedesArchiveId` and append-only assertions. Export creates a normative `.jazz-archive` ZIP;
the working draft directory is not itself the portable artifact.

## Verification gates

Tests must continue proving:

- start failure never enables capture or reuses an archive identity;
- stop waits for completed local producers, but never for network;
- AX/screenshot/audio timeout becomes an explicit gap;
- no callback can append after commit;
- crash/relaunch recovers every pending local event and blob exactly once;
- explicit live OTLP/Files compatibility derives from journal records without changing observation
  identity or CaptureCommit;
- same ID/same digest is idempotent and same ID/different digest is quarantined;
- finalized archives pass the shared JSON/golden validator;
- no control-plane request occurs before archive-level confirmation; and
- exact queue-owned bytes survive retries/relaunches while expired credentials, cancellation,
  rejection, quarantine, and conflicts retain local evidence.
