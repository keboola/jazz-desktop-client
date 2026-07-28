# ADR 0001 — Local-first Jazz archive and canonical capture evidence

- **Status:** Accepted (delivery policy refined by [ADR 0003](0003-confirmed-archive-delivery.md))
- **Date:** 2026-07-22
- **Scope:** Jazz desktop capture contract, future live transport, and the Jazz server consumer

## Context

The macOS client currently persists events in a local durability spool, maps them to OTLP, sends
them directly to a per-device Keboola Data Stream, and uploads screenshots and narration audio to
Keboola Files. The Jazz processor reconstructs a timeline by querying the resulting OTLP logs.

This works as a first transport, but it makes the transport representation part of the capture
contract. A completed recording is split across an append-only log stream and separately uploaded
blobs, there is no single portable session artifact, and transport timing affects when the server
can regard a recording as complete. It also makes later capabilities harder to align:

- offline-first capture and deterministic re-import;
- low-latency narration coaching;
- meeting audio, screen-share, and participant capture;
- work that spans multiple people, devices, and capture windows;
- cross-device replay; and
- generation and execution of governed agentic skills.

The current `sessionId` is also at risk of being overloaded. It identifies a recording window, but
it is not a reliable business process case: one recording can touch several invoices or tickets,
and one real process instance can continue across recordings, people, and devices.

## Decision

Jazz will move toward an **archive-first, transport-neutral evidence model**.

1. The client creates immutable canonical observation envelopes and artifacts locally before any
   network delivery.
2. A finalized `.jazz-archive` contains those same envelopes, artifacts, and a completion manifest.
3. A future live stream sends the same envelopes with the same identifiers. It is a low-latency
   transport, not a second event model.
4. Server ingestion is at-least-once and idempotent. Archive import reconciles any observations
   already received by streaming.
5. Process steps, process instances, object links, transcripts, replay plans, and skills are
   versioned derived records grounded in canonical evidence. They do not replace it.
6. Confirmed whole-archive delivery is the desktop default. Existing OTLP/Keboola Files delivery is
   retained only as an explicit `liveCompatibility` adapter and may not mint different evidence
   identities or a different completion boundary.

This decision defines the conceptual boundary, `ObservationEnvelope v1` archive contract, and the
Foundation journal/finalizer. It does not change the current `ActivityEvent` payload or OTLP mapping;
ADR 0003 defines the implemented confirmation, delivery, enrollment, and migration policy.

## Canonical records, derived records, and views

### Canonical source records

Canonical means “the immutable historical source of record”, not “an objectively true
interpretation”. Canonical records include:

- sensor observations and their capture-time context;
- screenshot, audio, video, and document bytes;
- user labels, annotations, narration, and explicit declarations;
- archive and capture-completion manifests;
- meeting-provider events and meeting-local participant claims;
- coaching questions or model messages that were actually shown to a person;
- human approvals, rejections, and corrections; and
- replay or skill execution receipts.

Once accepted, a canonical record is never edited in place. A correction is another record linked
to the original.

### Versioned derived records

Derived records include:

- speech-to-text transcripts and speaker diarization;
- identity resolution from an observed e-mail/display name to a known person;
- application and business-system resolution;
- gesture correlation, outcome inference, and copy-to-paste linkage;
- business-object references and process-instance membership;
- activity occurrences and handoffs;
- L4 processes, BDMs, ontologies, and other analytical models; and
- semantic replay plans and agentic skills.

Every derived record must identify its source references and source digest, generator type and
version (code commit, rule version, model, and prompt version as applicable), confidence, lifecycle
status, and the record it supersedes. Human review creates a new revision or approval record; it
does not rewrite source evidence.

### Rebuildable materialized views

Session lists, timelines, current-version pointers, search indexes, process inventories, and
monitoring aggregates are projections. They may be discarded and deterministically rebuilt from
canonical and derived records.

## Canonical observation envelope

`ObservationEnvelope v1` is transport-neutral and defined in the language-neutral archive
contract. It carries at least:

- globally unique `observationId`, `captureId`, a required globally unique `originId`, and optional
  engagement/meeting/conversation references;
- a locally minted `streamId` and sequence number scoped to that logical producer stream;
- occurrence wall-clock time plus monotonic tick and clock/boot-domain metadata;
- producer identity, kind, version/build, device identity, and source references;
- explicit actor attribution, including a status/reason when the actor is unknown;
- observation type, payload-schema identity, and typed payload;
- storage-neutral artifact references;
- optional non-causal correlation identifiers; causality is a provenance-bearing derived assertion;
- redaction-policy provenance and capture capabilities; and
- capture-quality status, including explicit gaps or missing permissions.

During migration an optional `legacyCorrelation` preserves today's `sessionId`, `eventId`, and
sequence so archive evidence can be reconciled with the existing OTLP projection without making
those legacy fields the new identity model.

The client appends the envelope to durable local state before it is eligible for streaming or
archive finalization. OTLP, archive import, and a future streaming protocol are adapters around
this envelope.

Payload dispatch is closed-world. A receiver accepts only a locally installed
`(recordType, payloadSchema, schemaVersion)` tuple advertised by the archive manifest or stream
contract negotiation. A schema URI is an identifier, never permission to fetch or execute remote
schema material. `originId` is carried on every envelope, so the same immutable record retains its
producer-origin identity outside an archive; actor and source definitions are supplied by the
manifest or by an equivalent authenticated stream-context registration before dependent records
are accepted.

For interaction evidence, the typed payload or a contract-declared context must preserve enough
portable source detail to support later interpretation: application identity and version, window
identity/title, action and modifiers, semantic target role/name, ordered namespaced locator
candidates, geometry with its coordinate space/display layout, and the capture capabilities that
were actually available. Process-local PIDs, native handles, and Accessibility identifiers may be
retained as source claims, but never treated as portable identities. The current OTLP projection may
remain narrower during migration; the archive must not discard this richer source evidence merely
because OTLP cannot represent it.

Server-assigned `receivedAt` and `ingestedAt` values are stored separately. They never replace the
capture occurrence time.

An offline archive may contain a cached tenant/project **claim** from enrollment, but that claim
never authorizes import. The server binds accepted bytes to the authoritative tenant from the
authenticated upload in a separate immutable ingest binding. Capture must not require a live tenant
lookup.

## Archive semantics

A `.jazz-archive` is an immutable package containing, conceptually:

```text
manifest.json
inventory.json
sessions/<sessionId>/
  session.json
  commit.json
  records.ndjson
  labels.ndjson
  artifacts.ndjson
  assertions.ndjson
blobs/sha256/<prefix>/<digest>
derived/...
```

The manifest identifies the archive format and observation schema versions, capture and producer,
the observation sequence range/count/digest, and every artifact's logical identifier, media type,
size, and digest. It also carries a capture completion record.

The archive is finalized from a crash-safe working directory through a temporary file and atomic
rename. The capture hot path does not depend on an appendable ZIP central directory. An interrupted
capture remains recoverable and can be finalized after restart.

User review is append-only. Confirmation, correction, exclusion, or redaction is represented by a
provenance-bearing assertion and does not rewrite the captured evidence in place. Finalizing after a
review creates a new immutable archive revision with a new `archiveId` and an optional
`supersedesArchiveId`; delivery policy may require an archive-level human confirmation assertion
before upload.

Large audio/video artifacts use a file-backed ingestion contract. A recorder writes directly into
a journal-owned claim and atomically seals it before ingestion; a caller cannot submit an arbitrary
mutable temporary URL. Hashing, transaction staging, integrity verification, finalization, and
large-media delivery are chunked so memory use is independent of artifact size. In-memory bytes are
only a convenience for bounded artifacts such as compressed screenshots.

### No local archive encryption in version 1

Jazz version 1 archives are **not encrypted locally by Jazz**. The design must not imply that an
archive is encrypted or introduce archive encryption keys, wrapping, or recovery flows.

The client still applies capture-time masking and denylist policy before persistence, writes local
data with owner-only filesystem permissions, makes recording state visible to the user, and applies
an explicit retention/deletion policy. Adding archive encryption later would require a separate ADR
and archive-format version.

## Identifier model and collision policy

### Identifier meanings

| Identifier | Meaning |
| --- | --- |
| `tenantId` | Authorization and data-isolation boundary. |
| `originId` | Globally unique offline-capable capture origin; never an authorization grant. |
| `engagementId` | A workshop, coaching engagement, or meeting that can group several captures. |
| `captureId` | One continuous acquisition window for one producer. This is the future internal meaning of today's `sessionId`. |
| `streamId` | One ordered logical producer stream, stable across transport reconnects. |
| `archiveId` | Globally unique opaque identity of one immutable archive revision. |
| `captureCommitId` | Identity of one immutable declared completion/reconciliation boundary. |
| `observationId` | Globally unique identity of one canonical observation. |
| `artifactId` | Storage-neutral identity of a screenshot, audio clip, video, or document. |
| `segmentId` | A bounded label/narration segment inside a capture. |
| `conversationId`, `turnId`, `utteranceId` | Coaching/interview conversation hierarchy. |
| `meetingId` | A meeting independent of any individual audio, screen, or desktop capture. |
| `processDefinitionId`, `processVersionId` | Stable process type and one immutable model revision. |
| `processInstanceId` | One real execution/case, potentially spanning actors, objects, captures, and devices. |
| `activityOccurrenceId` | One actual performance of a process activity. |
| `businessObjectId` | An object-centric process entity such as an invoice, ticket, or order. |
| `handoffId` | One observed, declared, or inferred transfer between activity occurrences/actors. |
| `skillId`, `skillVersionId`, `skillRunId` | Stable skill, immutable revision, and execution. |
| `replayPlanId`, `replayRunId` | Semantic replay plan and one execution attempt. |

### Generation and scoping

- Newly minted record identifiers use UUIDv7 (or an equivalent globally unique, time-sortable
  identifier).
- Content digests use SHA-256 and remain distinct from entity identifiers. An archive can therefore
  be identified before finalization while its final digest is still unknown.
- Deterministic legacy backfill uses UUIDv5 over a documented namespace including at least
  `tenantId`, legacy producer/source, legacy `sessionId`, and legacy `eventId`.
- Human-readable names, slugs, e-mail addresses, sequence numbers, screen coordinates, PIDs,
  window IDs, and Keboola Files IDs are never canonical entity identifiers.
- External business identifiers always include their source namespace and object type.
- Authorization always checks `tenantId` even when identifiers are globally unique.

### Collision handling

- Receiving the same `observationId` with the same canonical payload digest is an idempotent replay.
- Receiving the same `observationId` with a different digest is an integrity conflict. Neither
  payload silently wins; the import/stream is quarantined and the conflict is reported.
- Receiving identical payload bytes under different observation IDs represents two observations
  unless an explicit producer retry relationship proves otherwise.
- Receiving the same `archiveId` with the same final digest is an idempotent import. The same
  `archiveId` with a different digest is quarantined as an integrity conflict and never overwrites
  the accepted package. Identical final digests under different archive IDs may be deduplicated at
  the blob layer but retain both declared archive identities.
- A different digest for the same `captureId` requires an explicit increasing capture revision and
  `supersedesArchiveId`; otherwise it is a conflict.
- Sequence duplication or gaps are recorded as stream-quality facts. Sequence is never used as the
  primary identity.

## Actor, device, producer, and source identity

Jazz distinguishes:

- a **person**, whose stable `personId` may have several e-mail/provider aliases;
- an **actor**, which may be a human, software agent, or service;
- a **role assignment**, which is contextual and time-bounded;
- a **device**, which is an enrolled installation and can be shared or reassigned; and
- a **producer**, such as the macOS agent, browser extension, meeting bot, or agent executor.

An observation records the actor/source claim available at capture time and the device/producer
that made the observation. Mapping that claim to a known `personId`, role, application, or business
system is derived and versioned. Changing an e-mail or improving identity resolution never mutates
the observation.

Application identity is also separated from document identity. A bundle ID, executable, browser
URL, document URL, window, and derived business `systemId` are distinct fields/concepts. This is
required for reliable cross-device interpretation and replay.

## Capture sessions are not process instances

`captureId` answers “when and from which producer did we collect evidence?”

`processInstanceId` answers “which real business execution/case did this work belong to?”

They must never be aliases. A capture may contain several process instances, and an instance can
cross captures, meetings, users, devices, and days. Historical migration must leave an unresolved
process instance empty rather than assigning `processInstanceId = sessionId`.

Process-instance resolution is object-centric. An activity occurrence may reference several
business objects with roles such as input, output, subject, or destination. For example, one action
can intersect an Order, Customer, Shipment, and Payment. These intersections are preserved rather
than forced into one artificial case key.

## Multiple actors and handoffs

A derived activity occurrence links a process/activity definition to its time range, actor,
captures, business objects, and evidence. A handoff links a source and destination occurrence and,
where known, source/destination actors, transferred object/data, channel, initiation time, acceptance
time, and evidence.

Observed signals (for example a ticket assignment), user declarations (“I send this to Finance”),
and model inference are separate provenance-bearing records. They can support or contradict one
another; an inferred handoff never overwrites an observed or declared fact.

This model allows one process instance to be reconstructed from several users' archives and live
streams without merging their capture identities.

## Future live streaming and capture completion

Live delivery is at-least-once:

1. The client persists an observation locally.
2. It sends the immutable envelope with its stable ID and stream sequence.
3. The server idempotently stores it and acknowledges the highest contiguous accepted sequence.
4. Reconnect resumes after the acknowledged watermark.
5. Missing ranges remain explicit gaps.

Artifacts may arrive before or after referring observations. An unresolved artifact reference is a
valid pending state, not evidence that the artifact never existed.

At capture end, the client emits one immutable `CaptureCommit` declaring capture/revision identity,
per-stream first/last sequence and count, ordered observation digest, artifact-set digest, explicit
gaps, end time, and optional superseded commit/archive. A timeline received only over streaming is
provisional until this commit is satisfied. Importing the finalized archive supplies the **same
commit**, not an archive-only approximation, and reconciles the same observation IDs, making dual
delivery naturally idempotent.

Streaming must be an optional acceleration. Losing connectivity never stops capture or weakens local
durability.

### Capture finalization barrier

Stopping the visible recording is not yet a valid commit. The client first stops admitting new OS
input, closes narration segments, drains or times out in-flight Accessibility/screenshot/audio
enrichment, persists every completed observation/artifact, and records timed-out sequence ranges as
explicit gaps. Only then does it append the terminal observation and `CaptureCommit`. Late work may
create a new revision or a recovery record, but may never slip behind an already accepted commit.
`CaptureJournal` implements this barrier and keeps unfinished reservations recoverable across a
relaunch before the archive mirror can become authoritative.

## Live narration coaching

Live coaching uses the same evidence plane plus a conversation model:

- audio chunks are canonical artifacts;
- `conversationId`, `turnId`, and `utteranceId` identify the dialogue;
- partial and final speech-to-text outputs are versioned derived records;
- coach suggestions cite observations, artifacts, utterances, or transcript spans and record their
  model/prompt provenance;
- once a coach message is shown, that presentation is an immutable conversation/audit record; and
- user answers, acceptance, rejection, and corrections create new canonical records.

The coach evaluates **semantic coverage**, not vocabulary variety. For the activity currently being
shown it tracks whether narration supplies the intent, relevant input or business object, decision
rule, expected output, success criterion, exception path, and handoff. It should ask one short,
contextual follow-up only when a materially useful slot is missing; repetition, silence, confidence,
accent, or speaking style alone is not a process-quality defect. Every score carries the evidence
window, model/prompt version, uncertainty, and which modalities were unavailable.

The coach may act on a provisional live timeline. Final archive reconciliation can improve derived
interpretations but cannot rewrite what was shown or said. When semantic coaching is unavailable,
the client asks no questions. Early dogfood showed that a fixed checklist which does not inspect
the demonstrated work or narration is distracting and can be mistaken for an intelligent
assessment. Historical archives can still carry `localBaselineRef` so their provenance remains
readable, but new desktop captures surface only context-aware prompts backed by an `assessmentRef`.
Capture itself remains fully available offline.

## Meeting capture as another source

A meeting is an engagement with one `meetingId` and potentially several producers/captures:

- meeting audio;
- screen share;
- desktop capture from one or more participants;
- chat/calendar/provider events; and
- manually shown documents.

Meeting-local participant IDs and display names are canonical source claims. Speaker diarization,
speaker-to-participant mapping, and participant-to-`personId` resolution are derived. A speaker track
is not itself a person identity.

A screen-share producer normally observes pixels and meeting audio, not the remote machine's
Accessibility tree, raw keyboard input, application lifecycle, or trustworthy click targets. Its
capability/quality declaration must make those absences explicit; OCR, vision-based target recovery,
and inferred gestures remain derived. This lets meeting capture enter the same archive contract
without pretending it is evidence-equivalent to a native desktop collector.

A meeting can discuss multiple processes and business instances. It must not automatically create
one process instance or reuse `meetingId` as a case key. Its observations join later process
evidence through actor, object, activity, and explicit reference resolution.

## Replay and agentic skills

### Evidence replay

Evidence replay presents canonical observations and artifacts in time order. It must preserve
provenance, gaps, quality, and the distinction between capture time and ingest time.

### Executable replay

Executable replay is derived and versioned. It does not blindly replay raw coordinates or key
events. A replay plan uses semantic application and target identities, platform-specific locator
candidates, document/object context, parameters, preconditions, expected postconditions, device
capabilities, side-effect classification, and confirmation gates.

Raw PIDs, window IDs, coordinates, and captured secret values are not portable replay identities.
Each replay attempt has a `replayRunId` and emits new canonical observations/results; it never
changes the source plan or recording.

### Agentic skills

A skill is derived from a reviewed process version and evidence. A `skillVersionId` identifies an
immutable proposal containing input/output schemas, semantic actions, capability requirements,
preconditions/postconditions, parameter and secret references (never secret values), risk and
approval gates, compensation/rollback guidance, and test fixtures.

Generated skills remain `proposed` until a human approval record binds an approver to the exact
skill-version digest. A skill execution has a `skillRunId`, identifies the initiating actor and
approved skill version, and produces canonical observations and receipts using `actorKind = agent`.
Human and automated executions can therefore be analyzed through the same evidence model without
pretending that a generated plan is raw truth.

## Server import and read-model boundary

The server stores the uploaded archive as the canonical package and imports it through a durable,
restartable state machine. Validation includes manifest/schema/digest checks, bounded safe archive
expansion, and collision checks. Import state is persisted before work begins and advances through
checkpoints; current process-local terminal-only job persistence is not sufficient for this job.

The importer materializes storage-neutral artifact references into the server's artifact registry
and produces rebuildable capture-session and observation read models. Readers see an archive capture
only after an atomic `READY` publication. During migration a composite reader selects:

1. a ready archive projection when available;
2. otherwise the current OTLP projection; and
3. never a naive concatenation of both sources.

Shadow mode may compare the two sources by observation IDs, counts, timestamps, and digests without
serving duplicate events.

## Compatibility and rollout

The local journal, deterministic archive, explicit review, and whole-archive queue are implemented.
The server counterpart owns durable ingest and archive-backed read publication. OTLP/Keboola Files
remain available behind the explicit `liveCompatibility` switch for parity and rollback; they are no
longer the default capture path. A later minimal canonical stream may accelerate coaching and
provisional views, but the confirmed archive and byte-identical CaptureCommit remain completion
authority. Historical OTLP sessions stay readable through the compatibility adapter.

## Consequences

### Benefits

- One canonical evidence model works offline, in archives, and over future streaming.
- A completed capture is portable, auditable, deterministically re-importable, and reconcilable.
- Transport retries and dual delivery become idempotent by record identity.
- Capture windows, meetings, process instances, and business objects no longer share one overloaded
  identifier.
- Multi-actor handoffs, meeting evidence, replay, and skills can evolve without mutating raw data.
- Derived outputs carry explicit provenance, revisions, and approval state.

### Costs and risks

- The client must finalize and retain a coherent archive in addition to current delivery during
  migration.
- The server needs a secure archive importer, durable queue/checkpoints, artifact registry, and new
  projections.
- Archive and materialized artifacts can temporarily duplicate storage.
- Identity, process-instance, participant, and object resolution are new derived subsystems.
- Live and final views require explicit provisional/committed state.
- Compatibility adapters and old API aliases must remain until historical OTLP data and consumers
  have a supported migration path.

## Follow-up decision boundaries

Separate changes should define and implement, in dependency order:

1. the global ID and canonical observation-envelope contract;
2. storage-neutral artifact identity and registry;
3. the versioned archive manifest and importer;
4. unified archive/live-stream ingest and capture commit protocol;
5. actor/person/device/application identity resolution;
6. conversation, coaching, and meeting source contracts;
7. object-centric process instances, activity occurrences, and handoffs;
8. derived-record provenance and L4/BDM evidence v2; and
9. governed semantic replay and agentic skill definitions/runs.

None of these follow-ups should require a second raw-evidence model.
