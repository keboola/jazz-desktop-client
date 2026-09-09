# Continuous capture: bounded, reviewable sessions

Status: proposed; this change implements status grouping only, not automatic splitting.
Updated requirement: company deployment selects recording mode and upload authorization
independently; some companies require no per-session human review.

Panel review completed: [findings and implementation gates](reviews/continuous-capture-panel-2026-09-09.md).
Verdict: **READY WITH GATES** for safety work and review-only increments, not for enabling
unattended rotation or automatic upload. Thresholds and unresolved product choices below
remain proposals, not panel-approved deployment defaults.

## Recommendation

Extend the existing opt-in `continuousCapture` setting. Record locally in **30-minute
chunks**, end a chunk at **5 minutes of inactivity**, and immediately fence new capture
admission on **lock, sleep, logout, or user switch**. Stop physical sources before draining;
already-issued non-cancellable OS requests require separate qualification, and their
results must not admit evidence crossing a privacy boundary. Resume into a fresh chunk only when the user
is present, the system is unlocked, permissions are sufficient, and capture is still
explicitly enabled. User Pause in continuous mode must survive wake, reconnect, and relaunch.

These are initial, configurable defaults, not claims that a business task lasts 30
minutes. Labels describe activities; chunk boundaries bound storage and recovery.
Do not use app changes or AI guesses as automatic task-completion signals in v1.

**Recording mode and upload authorization are independent.** Automatic splitting alone
never authorizes delivery. The proposed company policy selects either per-archive human
review or automatic upload of eligible completed chunks under explicit company authority.
Automatic upload must not manufacture a human confirmation or imply evidence approval.
Rejection retains canonical local data in both modes.

### Deployment and first-run configuration

| Setting | Options | Safe default without company configuration |
| --- | --- | --- |
| Recording | Manual / continuous | Manual |
| Upload authorization | Human review per archive / company-authorized automatic upload | Human review |

Expose all four company preferences explicitly:

| Company preference | User recording controls | Completed-session delivery |
| --- | --- | --- |
| Manual + automatic upload | Start / Stop | Upload without per-session review |
| Manual + approval required | Start / Stop | Hold each session for approval |
| Continuous + automatic upload | Pause / Resume | Upload completed chunks without per-session review |
| Continuous + approval required | Pause / Resume | Hold each completed chunk for approval |

In manual mode, startup does not begin recording; Start opens a session and Stop
closes it. Internal safety chunking must not turn manual mode into auto-start mode.
In continuous mode, eligible startup begins recording automatically; expose Pause /
Resume instead of Start / Stop. Pause closes the current chunk and prevents further
capture until Resume. Neither Stop nor Pause grants upload approval: closed archives
follow the independent company upload policy. Employees cannot switch a managed
recording mode via these controls.

Prefer company-managed configuration delivered during installation/enrollment (for
example via MDM), rather than asking every employee to configure Settings. Display the
effective policy on first launch. For an unmanaged interactive installation, offer
these choices in first-run setup; persist them rather than ask at every startup.
Only an authenticated, authorized company administrator can grant automatic-upload
authority. An installer checkbox or ordinary local preference is not sufficient to
bypass a company review requirement. Managed restrictions cannot be relaxed locally.

First-run setup still explains what is captured, the destination, whether uploads
are automatic, and how to pause. Complete applicable user notice/consent and macOS
permission setup before capture starts. Installation configuration does not bypass
TCC; use supported managed permission mechanisms where available. Startup thereafter
follows the configured mode without repeated review/setup prompts. Keep a visible
recording/microphone indicator and the mode-appropriate Stop or Pause control.

### Automatic upload: required contract decision

The current repository explicitly permits finalization/enqueue only after archive-level
confirmation. **Automatic upload is a proposed contract change, not currently supported
or enabled by this plan.** Approve an ADR and update the governing requirements plus
shared contract/client/server together before implementing this second authorization path.
Do not repurpose `liveCompatibility` or emit synthetic `.confirm` assertions.

The new path must bind each eligible archive to validated company/device/scope authority
and its policy version, distinct from a person's review decision. Missing, invalid,
expired, or revoked authority holds delivery locally. Check authority at enqueue and
again before network delivery; the server must enforce the same scope and policy.
Use server-owned, company-scoped policy authority with monotonic generations. Policy
validity must be independent of credential rotation and enrollment reveal expiry.
Choose one representation in the ADR (signed enrollment extension or separate signed
policy document); reuse existing signing trust rather than introduce a second trust root.
MDM/local preferences may select or restrict behavior, but cannot mint this authority.
Profile removal, downgrade/replay, unknown freshness, and clock uncertainty hold delivery.
The MVP operator-handoff profile does not authorize automatic upload.

Check authority immediately before payload transfer as well as control-plane calls.
If revocation must prevent server acceptance, transactionally fence READY/ArchiveAccepted
publication against the policy generation; a check earlier in a worker is insufficient.
The ADR must define the exact delivery/revocation cutoff and bounded grant lifetime.

A change to automatic mode applies to newly started captures, not silently to an old
review backlog. Existing/imported/rejected/quarantined archives are not bulk released.
A change back to review-required holds not-yet-delivered work for review; specify and
test in-flight races explicitly, since already transmitted bytes cannot be recalled.
Normal transport retries remain automatic, but terminal rejection still requires an
explicit resolution. All modes retain local evidence on failure.

## What exists today

- `AgentSettings.continuousCapture` / `SettingsView`: opt-in start-on-launch toggle.
- `AppDelegate.autoStartCaptureIfEnabled()`: starts after launch/connect, but has no
  durable manual-pause state, segmentation policy, or sleep/idle lifecycle handling.
- `CaptureController.startAndWait()`: claims fresh identities and freezes capture
  policy before enabling capture; rejects starting while finalization is active.
- `CaptureController.stop()`: disables input, closes labels/audio, drains admitted
  work, and commits locally. It returns before its asynchronous shutdown task ends.
- `CaptureJournal` / `CaptureJournalRuntime`: reservations, WAL, commit barrier, and
  interrupted-capture recovery. Existing primitives should remain the single writer.
- `JazzArchiveLocalIndex`: local review read model; the sidebar now groups it with
  durable upload states. READY means ingest acceptance, not business approval or
  completed AI analysis. Imported/local-only archives must not imply remote delivery.

## Boundaries and resumption

The automatic-resumption rules below apply to **continuous mode only**. Proposed manual
behavior, pending product approval: Start arms recording; time/size safety splits may
continue only while that manual intent remains armed; Stop disarms immediately. Idle
or a privacy boundary ends manual intent, so wake/activity alone never starts another
recording. Settle narration continuation and workshop hard-limit behavior before release.

| Trigger | Boundary behavior | Resume behavior |
| --- | --- | --- |
| 30 minutes since chunk start | Close and commit, then start a fresh archive | Immediately after successful local close, if still eligible |
| 5 minutes without physical input | Close at detection time; retain the truthful captured interval, including the idle tail | First activity while unlocked, not a timer spinning up empty sessions |
| Explicit end of a labeled activity | Close label/audio; optionally also close the chunk via an opt-in setting | Remain armed for the next activity |
| Screen/session lock, system sleep, user switch/logout | Fence modality admission/results immediately; stop physical audio before drain; best-effort bounded local close | After wake/unlock and renewed activity; reject evidence acquired across the boundary |
| Display sleep | Pause screen capture conservatively in v1; qualify behavior on external displays and clamshell Macs | Once the display/session is active and the user returns |
| Manual Pause / disable continuous capture | Close locally and persist paused intent | Explicit Resume only; reconnect must not override Pause |
| Missing permission, full disk, unresolved close/recovery failure | Stop safely; show the concrete reason | User action after the fault is resolved, not an unbounded restart loop |
| Network outage or expired delivery token | Continue local capture in the default archive-only policy | Upload is independent and resumes through its durable queue |
| Crash / force quit | Recover the prior journal with honest gaps, never pretend it closed cleanly | Default to paused after an unclean exit; user resumes after recovery |

Use a monotonic clock for duration/idle deadlines and UTC wall-clock timestamps for
canonical evidence. Re-evaluate deadlines after wake; never generate missed chunks
for time spent asleep. Treat overlapping timer/lock/idle triggers as one boundary.
Input inactivity is only a heuristic: reading, calls, and narration may be active work.
While explicit narration/workshop activity is running, defer idle splitting; still
honor privacy boundaries and the hard duration limit. Keep guided BDM workshops out
of automatic rotation initially, showing that exception clearly.

## Minimal implementation

1. **Harden close/recovery first (release blocker).** `CaptureJournalRuntime.submit()`
   discards a claimed file on artifact-ingest failure while its artifact reservation can
   remain pending. Controller seal/admission failures also abandon audio claims. These
   paths can delete the sole recording, not merely stall Stop. Preserve failed media for
   recovery, distinguish invalid input from transient/unknown durability outcomes, and
   reconcile reservations against actual persisted evidence. Never delete evidence to
   unblock commit. Return committed-or-recovery-required within a bounded wait, even
   for non-cooperative producers. A timeout is not proof that a writer stopped: revoke
   abandoned generations and prevent recovery from taking the same archive while an old
   writer can still append. Remain blocked if writer/resource ownership is unresolved.
   Do not start automatic rotation on the current restart workaround.
2. **One lifecycle policy, not a second recorder.** Put deterministic time/idle/intent
   decisions in Foundation-only `JazzCaptureCore`. Keep `NSWorkspace` notifications,
   session/lock detection, input-idle queries, TCC checks, and timers in the executable.
   Qualify the lock/session signals on supported macOS versions; do not rely solely
   on a best-effort sleep notification or an undocumented notification as a privacy
   boundary. Unknown session eligibility pauses capture (fail closed). Check admission
   eligibility before every physical modality request and when accepting results, not
   only whether a callback has the right session ID. Stop physical audio before any
   live PCM backlog drain. Discard frames whose acquisition crosses a privacy boundary.
3. **Awaitable rotation.** Reuse start/stop through a serialized controller operation:
   `recording -> closing -> committed -> starting`. Fence every producer by the old
   capture generation; close typing/gestures, label spans and audio before commit.
   Do not just call `stop(); start()`—start currently refuses during finalization, and
   Stop ignores startup. Persist user intent before asynchronous work; gate initial
   startup on recovery completion and use the same owner for recovery/start/close.
   Recheck desired state and OS eligibility after every await so a lock or Pause
   during close cannot restart capture. Keep the initial implementation single-writer:
   a short, measured rotation gap is preferable to overlapping recorders. Surface
   the gap honestly; do not promise gapless recording.
4. **Fresh identities per chunk.** Preserve installation origin and enrolled scope,
   but mint new archive/capture/stream/observation IDs through the existing claim
   mechanism. A next chunk is not a corrected revision: do not abuse
   `supersedesArchiveId`. Never backdate a stop to the last input or silently move
   events/audio across chunks. On a timed boundary, continuing a label needs a new
   label ID and an explicit continuation relationship; sleep/lock ends it without
   automatic microphone restart.
5. **Bound resources.** Add a secondary chunk byte limit (initial proposal: 250 MiB,
   capped below the deployed server's verified archive-size limit with ZIP overhead
   headroom). Track pending media too; rotate before exceeding the usable limit.
   Measure bytes/hour, CPU, memory and close latency on real workloads before fixing
   defaults. Prune completed runtime task handles and cap outstanding AX/admission/media
   work; screenshot single-flight alone does not bound these queues. Budget all copies,
   claims, WAL/checkpoints, ZIP/finalization and emergency-close space, not only chunk
   payload size. Warn at a configurable local budget (initially 5 GiB); pause before
   free space falls below an emergency reserve (initially 2 GiB). Never age-delete
   unreviewed, rejected, quarantined, or delivery-pending evidence. Any later cleanup
   is a separate, explicit archive-management feature, not an upload retry behavior.
6. **Keep delivery independent.** Each authorized chunk uses the existing durable
   archive queue with identical bytes/digests across retries. Today authorization is
   explicit human confirmation; company-authorized automatic upload requires the
   contract change above, not a shortcut around the confirmation guard. Expired credentials,
   rejection, cancellation, or network errors must not destroy local chunks. Retain
   `liveCompatibility` only as an explicit migration policy; continuous local-first
   capture should not depend on its services or Capture Coach Live availability.

## UI proposal

No additional panel is necessary just for grouping. Use the native sidebar's
collapsible status groups and counts, newest first within each group, preserving
selection as upload state changes. Empty groups stay hidden. Upload retry, failure,
local rejection, and server rejection remain distinguishable.

Use the same small **Recording and upload policy** section in first-run setup and Settings:

- manual/continuous recording; effective human-review/automatic-upload policy;
- company-managed indicator and read-only controls where policy is enforced;
- enabled/paused state; maximum chunk duration; idle threshold;
- optional split on End activity; byte/disk-budget limits;
- destination and clear explanation of whether each archive needs human review.

Persist first-run readiness and a truthful notice/consent receipt separately from company
policy and Pause. Do not stamp each automatic rotation as a new human consent event:
current capture-start `consentedAt` is not proof of renewed consent. Define renewal for
material changes to modalities or destination; upload authority never enables additional
modalities. Show actual microphone activity rather than inferring it from a label.

Initial deployment scope should reuse managed/enrollment policy plus first-run setup;
a custom installer wizard is optional, not an existing capability. Decide whether
startup means app launch only or also login registration. Align release/permission
documentation with required enrollment trust and the actual screenshot preflight.

In review-required mode, completed chunks enter Needs review. Under the proposed
company-authorized mode, eligible chunks enter the upload queue without a per-session
dialog and display “Automatic upload — company policy”, not “Reviewed/confirmed by you”.

The menu bar should always distinguish **Recording**, **Closing chunk**, **Armed—
waiting for activity**, **Paused by you**, and **Blocked—action needed**. Include
Start / Stop in manual mode and “Pause until I resume” / Resume in continuous mode;
show elapsed time and, where automatic chunking applies, the next timed split.
An optional “Finish chunk now” action in continuous mode rotates the archive without
turning recording off. Do not hide microphone activity behind a generic recording indicator.

As volume grows, add date/text filtering and a daily review view over the same
archives. In review-required mode, explicitly reviewing a selected batch can confirm
each listed archive; a local convenience toggle cannot override that requirement.
Keep segmentation and upload authorization independent from business-task assignment
and downstream human/AI review.

## Metadata and contract coordination

Local intent/settings and status grouping do not change emitted evidence. If chunk
boundary reasons, recording-series links, or label-continuation metadata are emitted,
first specify their canonical representation and privacy meaning. Update the shared
schema, golden fixtures, Swift runner, and Jazz processor mirror together, including
any affected OTLP projection. The company-authorized upload policy and per-archive
authorization evidence likewise require coordinated schema, golden fixture, Swift
runner, and processor changes. Do not add ad-hoc wire fields solely for the sidebar.

For the first timer-only release, each chunk can remain an ordinary existing archive;
local grouping by date needs no portable recording-series abstraction. Add that link
only when server-side cross-chunk playback/analysis actually needs it.

## Executable implementation plan

Planning only: the checklist below has not been implemented. Status grouping is the
existing completed slice. Work in small reviewable commits/PRs; preserve the installed
app, recordings, uncommitted work and server-main documents. Do not deploy or change
company policy as a side effect of tests. One writer per worktree.

Desktop paths below are relative to `macos/Sources/`; server paths are relative to
`apps/processor/src/jasnost_processor/` in the Jazz server repository. Before coding,
reconfirm the current branches/heads and rebase the plan's source assumptions against
the intended upstream baseline; the panel reviewed desktop `0bbe400` and server `5a5a642`.

Dependencies: `M0 → M1 → M2`; M3 specification can proceed alongside safety work.
M4 managed-policy integration and M6 require the approved M3 contract; M5 uses M2/M4
readiness. M7 joins safe capture and compatible server authorization; M8 is the release
gate. Review-only safety/UI improvements do not wait for automatic-upload authorization.

### M0 — Baseline and regression cases

- [ ] Capture repository/build/test baselines without changing real capture data.
- [ ] Reproduce claimed-audio deletion, unresolved artifact reservations, Pause during
  startup, late screenshot admission and non-cooperative close with temporary test roots.
- [ ] Record each failing check before fixing it. Existing suites to extend:
  `CaptureJournalRuntimeTests`, `CaptureJournalTests`, `CaptureJournalProcessKillTests`,
  `ScreenCaptureEvidenceTests`, `AutoStartTests`, and `JazzArchiveUploadTests`.

**Exit:** failures are deterministic, evidence-preservation assertions are explicit,
existing unrelated failures are identified, and production recordings are untouched.

### M1 — Preserve media and make recovery ownership safe

**Desktop seams:** `JazzCaptureCore/CaptureJournalRuntime.swift`, `CaptureJournal.swift`,
`JazzArchiveFileIO.swift`, and `JazzCapture/CaptureController.swift` claim error paths.

- [ ] Retain recoverable recording/sealed claims on persistence failures; resolve
  artifact reservations only after reconciling actual durable state.
- [ ] Give close an explicit committed/recovery-required outcome and a bounded wait.
  Do not merely wrap an unbounded writer in a timeout; old writer ownership must be
  revoked or proven quiescent before recovery can touch the same archive.
- [ ] Prune completed producer handles, bound outstanding work, and reserve disk space
  for failed-media retention and close/finalization work.

**Exit:** injected seal/copy/fsync faults preserve the sole recording; crash/relaunch
reconciles it exactly once; late writers cannot append after commit or race recovery.
No wire-contract change or automatic upload is required for this milestone.

### M2 — One lifecycle owner and correct Start/Stop/Pause/Resume

**Desktop seams:** `JazzCapture/CaptureController.swift`, `AppDelegate.swift`,
`Capture/Narration.swift`, screenshot/AX request paths, and `JazzCaptureCore/AutoStart.swift`.

- [ ] Represent effective recording mode, persisted user Pause, first-run readiness,
  and runtime lifecycle separately. Manual Start intent does not survive app restart.
- [ ] Serialize recovery/start/close; persist Stop/Pause intent before awaiting work.
  Recheck eligibility after awaits and immediately before enabling physical sources.
- [ ] Fence requests/results at Stop, lock, sleep and session switch; stop audio before
  advisory PCM drain. Integrate qualified OS signals only in the executable target.
- [ ] Route menu, settings, reconnect and startup through the same eligibility logic.
  Expose Start/Stop for manual mode and Pause/Resume for continuous mode; show actual
  microphone state and explicit paused/blocked/closing status.

**Exit:** reconnect/relaunch cannot undo Pause; Stop during startup never enables input;
privacy-crossing frames are rejected; source shutdown and recovery races pass. Keep
review-only upload unchanged. Real-Mac OS boundary checks are required before release.

### M3 — Specify and approve company policy authorization

**Can be drafted alongside M1/M2; blocks automatic-upload code, not safety fixes.**

- [ ] Draft a proposed ADR under `docs/adr/`; do not silently amend accepted ADR 0003
  or the confirmation-only governing requirements.
- [ ] Define the policy authority, company administrator permissions, precedence,
  generation/expiry/refresh rules and independent recording/upload fields. Choose
  signed enrollment extension versus separately signed policy once, reusing trust.
- [ ] Specify capture-start eligibility, per-archive authorization binding, and the
  current-authority check before each delivery attempt; imported assertions are not
  company authority. Define data-to-hash boundaries to avoid self-referential digests.
- [ ] Specify revocation cutoff, in-flight grant lifetime and publication fencing;
  policy changes must not retroactively release held/rejected/imported archives.
- [ ] Define how an already sealed automatic archive is held or genuinely approved
  after policy changes without modifying queue-owned bytes; choose a coordinated
  authorization mechanism or explicit revision path rather than an ad-hoc workaround.
- [ ] Review and approve the exact schema/API semantics before implementing the second
  delivery path. Company authorization remains distinct from human evidence approval.

**Exit:** the ADR resolves the decisions below, includes positive/negative fixtures and
migration behavior, and the governing confirmation-only rule has an explicitly approved
coordinated replacement. Until then automatic-upload choices are unavailable, not fake.

### M4 — Deployment configuration and first-run setup

**Desktop seams:** `JazzCapture/Settings.swift`, `SettingsView.swift`, `AppDelegate.swift`,
`JazzEnrollmentSecurity/` trust/acceptance code, and `macos/README.md`/release tooling.

- [ ] Resolve managed policy over permitted local preferences; invalid or removed
  policy cannot relax review requirements. Restrict managed fields in Settings.
- [ ] Reuse a single Recording and upload policy view in first-run setup and Settings.
  Display company, destination, modalities, recording controls and delivery behavior.
- [ ] Persist setup/notice readiness independently of policy and Pause. Do not use a
  capture-start timestamp to manufacture a fresh consent event on every rotation.
- [ ] Support policy provision at deployment/enrollment with first-run fallback. Keep
  custom installer UI out of the first slice; installation does not bypass TCC.
- [ ] Implement login registration only if selected in the startup decision below.

**Exit:** clean install, upgrade, permission denial/relaunch and policy removal preserve
intent and local data; no capture before setup is ready. Review-only functionality can
ship first; automatic mode stays visibly unavailable until M6/M7 capability checks pass.

### M5 — Bounded session splitting, initially with review-required delivery

**Desktop seams:** existing controller/journal plus one Foundation-only boundary policy
with injectable clock/idle inputs; native timers and OS adapters remain in the executable.

- [ ] Implement time and byte limits, then idle/activity boundaries after qualification.
  Coalesce simultaneous timer/idle/lock events into one close operation.
- [ ] Await successful local close before starting the next archive. Mint new IDs;
  preserve scope, truthful timestamps and explicit label/audio boundaries. Never
  use `supersedesArchiveId` merely to link adjacent chunks.
- [ ] Recheck current intent/readiness after close; no restart after manual Stop,
  continuous Pause, unresolved failure or privacy ineligibility.
- [ ] Apply the agreed manual-mode, narration and workshop rules. Reserve headroom
  for pending media, queue packages and server limits; pause rather than erase data.

**Exit:** deterministic boundary tests, no duplicate/late writes, no empty catch-up
archives after sleep, bounded outstanding work and measured rotation gaps. Completed
chunks enter Needs review until the approved automatic authorization path is available.

### M6 — Coordinated contract and server implementation

**Shared seams:** `contract/archive/`, `contract/enrollment/` where affected, validators,
golden/container fixtures, Swift contract runners, and server `contracts/desktop/` mirror.
**Server seams:** `device_control_plane.py`, `enrollment_signing.py`, `api.py`,
`archive_http.py`, `archive_scope.py`, `archive_worker.py`, `postgres_archive_ingest.py`
and the corresponding reference/SQLite stores.

- [ ] Implement company-scoped policy administration, durable generations and refresh.
  An existing deployment-wide admin allowlist is not automatically a company role.
- [ ] Add the approved automatic authorization branch alongside unchanged human review;
  bind admission to archive identity, digest, exact ZIP hash and length.
- [ ] Revalidate at grant/finalize/verification/import and transactionally fence READY
  where required by the ADR, including recovery and alternate store paths.
- [ ] Advertise supported authorization versions separately from transport readiness;
  expose effective limits needed by chunk sizing. Add backward-compatible migrations.

**Exit:** archive HTTP/worker/store/enrollment tests cover both branches, cross-company
and stale/revoked authority, recovered finalize, replay and mixed versions. All shared
validators/runners and processor CI pass. Deploy readers/stores and every worker replica
before enabling clients; a generic HTTP 200 or green readiness icon is not this gate.

### M7 — Automatic client delivery and four-mode integration

**Desktop seams:** `JazzCaptureCore/JazzArchiveUpload.swift`, finalizer/importer/review
boundaries, `JazzCapture/ArchiveUploadClient.swift`, `MainView.swift`, and `SessionStatusGroup.swift`.

- [ ] On successful session close, select the approved authorization path: hold for
  human approval or finalize/enqueue under verified company policy. Never emit `.confirm`
  for automatic mode. Stop, Pause and automatic split all use this same close result.
- [ ] Persist exact package/operation/authorization bindings before network. Revalidate
  current policy at retries and before payload transfer; credentials remain in Keychain.
- [ ] Hold delivery for unknown authority/capability, without discarding bytes or changing
  a user's Pause state. Normal transient retries are automatic; terminal rejection is not.
- [ ] Show honest states: Held for review, Automatic upload — company policy, authority
  blocked, uploading, processing, and server accepted. Do not label automatic archives
  as reviewed by the employee or rewrite old backlog to make it eligible.

**Exit:** all four modes pass end-to-end, including offline-to-online retry with valid
authority, policy expiry/revocation, relaunch, corrected/imported archives and preserved
ZIP bytes. Review-mode confirmation tests remain unchanged and passing.

### M8 — Pilot, rollout and rollback

- [ ] Run overnight/multi-day trials on the signed app at `/Applications/Jazz Capture.app`:
  reading/calls, narration, external displays, sleep/lock, disk pressure and slow/offline
  delivery. Measure resource growth and close latency; inspect actual captured artifacts.
- [ ] Verify authenticated server list/detail/media and archive scope, not readiness alone.
- [ ] Enable per company after both peers pass capability/authority gates; monitor capture
  loss, stuck closes, backlog, policy holds, duplicate identities and rejected uploads.
- [ ] Rollback disables automatic admission and holds unaccepted work according to the
  agreed cutoff. Preserve stored policy provenance, queue packages and all local data.
  Do not downgrade to human confirmation or claim already uploaded bytes were recalled.

**Exit:** deployment receipt, validation evidence and known residual OS/grant limitations
are recorded. No unattended/gapless claim before real-Mac qualification.

### Decisions needed before their milestone

| Decision | Recommendation / scope | Blocks |
| --- | --- | --- |
| Manual boundaries and thresholds | Safety time/size splitting only while manually armed; no idle/wake restart. Tune 30 min / 5 min and storage ceilings with real traces. Confirm narration/workshop boundary behavior. | M5 |
| Startup behavior | App-launch startup in v1; login startup as an explicit managed option, not an assumed installation side effect. | M4 login integration |
| Company policy lifecycle | Server-owned company role; independent version/validity; fresh validation for delivery, fail-closed on uncertainty; exact offline lease, revocation cutoff and held-package approval specified in ADR. | M3, M6, M7 |
| Notice and modalities | Persist truthful setup receipt; renew for material destination/modality changes; automatic upload grants no new capture modality. Define renewal and any separate delivery-hold requirement. | M4, M7 |

These choices do not block M0–M2. A panel recommendation is not product approval.

## Validation gates

Tests must cover timer rollover, input-idle edge cases, monotonic clock vs wall-clock
jumps, label/audio closure, delayed callbacks, failed artifact persistence, full disk,
crash during rotation, repeated sleep/wake, Pause during close/start, and no capture
while locked. Verify no duplicate IDs, no post-commit append, and no upload without
valid authorization: human confirmation in review mode, or the proposed company policy
in automatic mode. Cover all four recording/upload combinations, managed-policy override
attempts, missing/expired/revoked authority, policy changes during queued/in-flight work,
and no retroactive release of the existing backlog. Until that new contract ships,
retain the existing no-upload-before-confirmation test unchanged. Add fault-injected
seal/copy/fsync failures proving retained recoverability, physical audio-stop ordering,
late screenshot requests/results, concurrent recovery exclusion, and outstanding-work
ceilings. Exercise revocation immediately before READY and mixed-version worker rollouts.
Run overnight and multi-day real-Mac trials, including reading/calls,
external displays, offline operation, slow uploads and lock during screenshot/audio
work. Track memory/disk growth and p95 close latency; qualify all before describing
this feature as unattended or gapless.

At higher archive counts, benchmark `JazzArchiveLocalIndex` separately: grouping is
one pass over summaries, but loading still reads/verifies archive evidence. Only if
measured loading becomes unacceptable, add an invalidatable local summary cache and
pagination; keep playback/export integrity verification mandatory. Do not rehash all
historical archive content on every recording indicator tick.
