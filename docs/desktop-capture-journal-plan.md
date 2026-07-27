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

### Bounded hot-path persistence

The coordinator uses a backwards-readable `state.json` checkpoint plus immutable, monotonically
numbered WAL segments under `.capture-journal/<archiveId>/wal/`. Reserving or resolving one
observation/artifact writes only that mutation; it never rewrites the growing reservation ledger.
The in-memory document is reference-owned by the actor so nested stream arrays do not incur a
copy-on-write traversal for every event. Relaunch applies contiguous WAL segments, validates the
complete reconstructed ledger, reconciles write-ahead intents idempotently, writes one new
checkpoint, and retires old segments. The checkpoint carries the first unapplied WAL sequence, so a
crash while retiring segments can neither duplicate nor skip a mutation. Pre-WAL `state.json`
documents remain valid and reopen with sequence zero. Replay builds stream, reservation and artifact
indexes once from the checkpoint and updates them with each segment, so relaunch validation and WAL
application are linear in ledger size rather than repeatedly scanning the growing ledger.

The working archive follows the same rule. Journal-owned record batches and artifact/blob documents
are immutable and fsynced directly; the live manifest and portable inventory are not rewritten for
each append. A fresh process performs one strict scan to rebuild its identity index, after which
duplicate observation IDs and `(streamId, streamSequence)` keys are checked incrementally. The end
transaction fingerprints every deferred file and atomically materializes the complete portable
inventory, manifest, session and `CaptureCommit`. Finalization still compacts record batches to the
contract-defined `records.ndjson`, so the exported archive format and bytes do not expose this draft
implementation.

This makes durable bytes and mutation work grow with the newly admitted evidence (amortized
`O(delta)` per append), with one intentional `O(n)` verification/checkpoint at relaunch and commit.
An fsync with an unknown outcome fails the writer closed; retry/relaunch verifies and
resynchronizes already-published identical bytes before acknowledging the producer.

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

The source descriptor written before capture is deliberately conservative: it claims no OS evidence
capability before the first durable capability observation, while frozen policy exclusions are
listed as `disabled_by_policy`. At CaptureCommit, one linear reduction of the canonical typed
capability observations materializes the static source summary. A capability that was available at
least once is listed in `source.capabilities`; one that was never available is listed only in
`unavailableCapabilities` with a stable mapped reason. Temporary outages and revocations remain in
the typed timeline and do not erase evidence supplied earlier. A policy-requested modality that was
never supplied makes session quality `partial` with a deterministic
`capture_capability.<capability>.<reason>` token; an intentional policy-disabled modality does not
degrade quality.

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
- four times as many observations or artifacts produces approximately four times, not sixteen
  times, the measured WAL/draft payload bytes while checkpoint manifest/inventory sizes stay flat;
- every actual SIGKILL lifecycle boundary reconstructs the same ledger and canonical bytes;
- pre-WAL checkpoints reopen and continue at the next contiguous stream sequence; and
- the deferred draft end checkpoint and finalizer produce a complete inventory plus the same
  portable `records.ndjson` layout.
