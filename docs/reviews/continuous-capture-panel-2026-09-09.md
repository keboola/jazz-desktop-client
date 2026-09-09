# Company recording/upload policy — panel review

Date: 2026-09-09. Scope: design review, not implementation or release approval.
Plan: [Continuous capture](../continuous-capture-plan.md).

## Verdict: READY WITH GATES

Ready to implement prerequisite safety fixes and review-only increments. **Not ready
to enable unattended rotation or company-authorized automatic upload.** All four review
lanes completed, followed by an independent synthesis pass; no lane failed. These were
five fresh-context agent runs using the same configured model, not a cross-model panel
or a legal/privacy certification.

The panel agrees with the requested product matrix:

| Recording | Controls | Upload policy |
| --- | --- | --- |
| Manual | Start / Stop | Automatic, under valid company authority |
| Manual | Start / Stop | Hold each archive for human approval |
| Continuous | Pause / Resume | Automatic, under valid company authority |
| Continuous | Pause / Resume | Hold each chunk for human approval |

Deployment configuration takes priority over first-run preferences where managed.
Recording mode, persisted user intent, setup/consent readiness, and delivery authority
are distinct. Pause stops future capture; closing the chunk still follows upload policy.

## Reviewed evidence and limitations

Desktop: `jazz-desktop-client`, HEAD `0bbe400`, with the uncommitted status-grouping
change and plan. Server: `jazz-remove-mvp-badge`, HEAD `5a5a642`. The dirty sibling
server-main worktree was outside scope. Source locations below refer to these review
snapshots and may move during implementation.

Reviewers read source and tests. They did **not** run tests, reproduce failures on a
real Mac, inspect credentials, deploy, commit, or change application code. The parent
spot-checked the audio cleanup, Stop/start, narration stop ordering, consent timestamp,
client confirmation and server confirmation/publication seams. Findings about code
paths are not claims that a particular user's recording was lost.

## Findings and disposition

### 1. Recorded media preservation — blocking prerequisite

**Current code path:** `macos/Sources/JazzCaptureCore/CaptureJournalRuntime.swift:273–283`
handles any artifact-ingest error by discarding the claim, while only resolving the
observation gap. Artifact reservations can remain pending. Controller seal/admission
failure paths also abandon recording claims (`CaptureController.swift:2837–2844,
3076–3078`). `JazzArchiveFileIO.swift:96–99,126–128` implements deletion.

**Accepted amendment:** preserve potentially sole-source audio/claims; distinguish
invalid input from transient/unknown durability outcomes; reconcile durable evidence
and reservations before recovery/commit. Do not delete media to make Stop succeed.

**Gate:** fault injection at seal, copy, sync, publication and reservation resolution;
prove bytes remain recoverable and close reports an honest result. Tests must cover
successful recovery, not just rejection of a changed file.

### 2. Stop/Pause and physical privacy boundaries — blocking prerequisite

**Current limitations:** Stop ignores startup (`CaptureController.swift:1049–1050`).
Delayed enrichment checks capture identity, which does not itself prohibit a new
screenshot after Stop (`:2130–2190`). Narration drains live PCM before stopping the
canonical recorder (`Capture/Narration.swift:65–73`). Reconnect/launch can restart
continuous capture without durable Pause (`AppDelegate.swift:534–565`). Startup
recovery is not an explicit gate in start ownership.

**Accepted amendment:** one serialized owner for start/close/recovery, persisted intent
before awaits, immediate modality-admission/result fences, and physical audio stop
before drain. Privacy boundaries reject crossing-frame evidence. A generation check
or timeout does not prove physical OS capture ceased; qualify already-issued,
non-cancellable requests without promising instantaneous termination.

**Gate:** Pause during start/close, reconnect after Pause, lock during AX/screenshot/audio,
late callbacks, startup recovery races, and real-Mac microphone/lock qualification.

### 3. Close deadlines and resource ceilings — blocking prerequisite

**Current limitations:** `CaptureJournalRuntime.swift:400–422` awaits producers without
a deadline. Returning from a quit deadline does not stop the original writer. Runtime
retains completed task handles until commit; its pending count is not a count of only
unfinished work. Screenshot single-flight does not bound AX/admission backlog.

**Accepted amendment:** committed/recovery-required close result, sealed admissions,
revoked abandoned generations, and no second owner of an archive while old writes
remain possible. Block restart on unresolved ownership. Prune completed work and cap
outstanding tasks/media; reserve disk for claim copies, WAL/checkpoints, finalization
and emergency close, not just one chunk's payload.

**Gate:** non-cooperative producers, timeout followed by late writes, recovery exclusion,
full disk at each lifecycle edge, and overnight/multi-day memory and disk trials.

### 4. Automatic-upload authority — contract gate, not a current defect

The current client deliberately calls finalization with `requireArchiveConfirmation:
true` (`JazzArchiveUpload.swift:2560–2568`). The server requires effective confirmation
by an identified human (`apps/processor/src/jasnost_processor/archive_worker.py:907–939`).
`AGENTS.md` and ADR 0003 require this behavior. Signed enrollment currently supplies
credentials/routing, not automatic-upload policy authority.

**Accepted amendment:** first approve a new ADR and coordinated requirements/contract
change. Define versioned company-scoped policy and per-archive authorization distinct
from human review. Bind immutable identity/digests and eligible capture-start scope;
keep credentials, renewable grants and mutable delivery eligibility outside immutable
archive bytes. No synthetic `.confirm`, ordinary local checkbox, MVP handoff, imported
metadata or transport token may substitute for company authority.

**Gate:** shared schemas/goldens/validators, Swift runner/client/finalizer/importer/queue,
processor mirror/worker and affected stores change together. Human-confirmation behavior
and historical fixtures remain valid. Add forged/imported/cross-company policy tests.

### 5. Authority lifecycle, revocation and rollout — design gate

**Omission:** administrator scope, policy precedence/removal, offline validity, freshness,
and in-flight cutoffs need executable definitions. A worker's early authorization
check is not a transactional publication fence; existing `postgres_archive_ingest.py:
915–1014` publishes READY without a company-policy-generation gate.

**Accepted amendment:** server-owned company authority, monotonic policy generations,
independent policy/credential lifetimes, fail-closed delivery on uncertainty, and checks
at enqueue/retry/pre-transfer and server grant/finalize/verification/import. If revocation
must prevent READY, fence publication in its transaction. Already transferred bytes
cannot be recalled; bound direct-grant lifetime and specify the residual window.
Never silently release pre-policy, imported, rejected, quarantined, cancelled, or held
backlog. Specify genuine approval of a held immutable package without modifying it.

**Gate:** all server readers/stores/workers upgraded before client activation; explicit
authorization-capability negotiation, mixed-version tests, revocation at every boundary,
unchanged queued bytes across retries/rollback. Missing capability holds automatic work.

### 6. Deployment, consent and mode-specific UX — design gate

**Current limitations/omissions:** release tooling produces an app/ZIP, not an existing
company-policy installer wizard. First-run readiness needs its own persisted state.
`CaptureController.swift:1605–1621` stamps consent time at capture start; rotation must
not claim that timestamp proves renewed human consent. Menu microphone indication is
currently tied to a label rather than actual recorder activity. Manual-mode sleep/idle
behavior and login-vs-app-launch startup were not settled.

**Accepted amendment:** managed policy plus first-run fallback as the minimal deployment
slice; truthful policy/modality/destination display, readiness/notice receipt separate
from Pause, actual microphone status, and no modality expansion through upload authority.
Align permission/release docs with actual screenshot preflight and enrollment trust.
Do not promise that installation bypasses macOS permission requirements.

**Gate:** four-mode matrix across permissions, relaunch/reconnect, policy replacement/
removal, managed-override attempts, offline capture and unchanged prior backlog.

## Differences resolved or deferred

- **Policy packaging:** reviewers suggested an enrollment extension or a separately
  signed policy document. No architecture chosen yet. Reuse existing signing trust;
  keep policy generation/expiry independent of credentials. Decide in the ADR.
- **Sequencing:** policy specification may run alongside safety engineering, but no
  deployment feature bypasses privacy/durability prerequisites. Review-only slices
  can ship before automatic authorization.
- **Revocation:** a transactional READY fence is needed only if the agreed cutoff
  promises to prevent acceptance; weaker guarantees must be explicit, not accidental.
- **Defer:** second recorders/services, gapless-overlap machinery, AI task boundaries,
  recording-series schemas, custom installer wizard, summary caches/pagination and
  batch-review automation until there is demonstrated need.

## Product decisions still requiring approval

These are recommendations, not decisions silently made by the panel:

1. **Boundaries:** confirm/tune 30-minute chunks and 5-minute idle, with byte/disk defaults
   validated against server limits and real traces. Proposed manual behavior: safety
   time/size splits may continue while Start remains armed; Stop disarms, and idle/wake
   cannot auto-resume. Settle narration continuation and workshop hard-limit handling.
2. **Authority lifecycle:** company administrator scope, policy validity/offline lease,
   open-capture policy changes, exact definition of delivered/revoked, and held-package
   approval semantics. Recommend fail-closed automatic delivery when authority is
   unknown; retain eligible local capture and all evidence.
3. **Consent/controls:** notice renewal on material destination/modality changes,
   app-launch versus login startup, and whether a separate delivery-hold control is
   needed. Existing request establishes that Pause is a recording control, not deletion
   or retroactive upload cancellation.

## Implementation sequence

1. Reproduce and fix media preservation, physical privacy, intent and writer-ownership
   failures with focused tests; no authorization change required.
2. Durable Pause/manual disarming, first-run readiness and truthful status/policy UI,
   with existing review-only delivery.
3. Serialized opt-in time/size rotation once safety/resource gates pass.
4. Approved authorization ADR and coordinated server-first rollout; enable the two
   automatic-upload combinations only after capability/authority checks pass.
5. Qualify idle behavior and unattended operation on real Macs.

Run the full desktop AGENTS validation suite and affected processor CI after code
changes. This panel supplied design/source evidence, not runtime certification.

## Review receipt

Workflow: `36dacf85-2b0d-40e5-a82f-d57ec1f1ec17`.
Mission: `04077b63-47a8-41f8-9a67-6f932d0754e7`.

| Lane | Completed run |
| --- | --- |
| Capture lifecycle/durability | `ce636beb` |
| Authorization/privacy | `e2d08397` |
| Server contract/migration | `e1de67f5` |
| Deployment/operator UX | `c2670d7c` |
| Independent synthesis | `b4689e12` |

Parent disposition: accepted the blockers and amended the plan; preserved the current
confirmation-only rules. No automatic upload, policy change, or new recording behavior
was enabled by this review.
