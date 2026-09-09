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

Implementation mission: `eaa688eb-49f0-4b14-a71f-c4c9cc18b8fd`, cumulative authorized budget
**3,200,000 tokens** (including the latest 1,600,000 continuation; usage below is pre-M3).
Worktree: `/Users/maziak/Devel/acl/jazz-desktop-continuous-capture`, branch
`feat/company-recording-policy`. Seed commit: `5be5a7b` (status grouping and reviewed plan,
based on the existing resubmission branch at `0bbe400`). The original checkout and
its independent Windows documentation branch remain untouched.

### Acceptance and evidence ledger

After M4a repair review: **3,200,000 authorized; 2,363,685 child input/output tokens
used; 836,315 remain**. M4a added 273,750 writer/initial-review and 264,479
repair/fresh-review tokens to the prior 1,825,456. All prior debits, detached usage and
the earlier overrun remain included. Native zero accounting is not authoritative. Mission active,
not complete; proposed-document acceptance is not governing approval.
M2a, M2b1 and scoped M2b2/M2c code are accepted; the last two passed repair round 1/3.
M3 now has a proposed-only [ADR](adr/0005-company-recording-policy.md) and
[evidence note](evidence/continuous-capture-m3.md); fresh review passed after repair round 1,
but governing activation approval remains unresolved. M4a review-only enrollment/setup readiness is
accepted after repair round 1, independent of automatic upload and the unqualified unattended
OS gate; the applicable M5–M8 gates remain ahead.
The current confirmation-only rule cannot be bypassed by deployment permission.
Each slice gets a sole writer then fresh review with at most three repair rounds.
Keep full M1/M2 acceptance open until all related slices and qualification gates pass.

| Milestone | State | Acceptance / evidence |
| --- | --- | --- |
| M0 baseline/regressions | Partial | Baseline passed; three media/task regressions reproduced. M2 added synthetic startup/privacy race checks; native qualification remains. [Evidence](evidence/continuous-capture-m0-m1.md). |
| M1 media/recovery | Partial; repair round 1/3 accepted | Fresh reviewer `121cf3e0` passed the safe partial diff with no blocking findings. Parent reran six contract checks + Swift build/test: 746 executed, 1 live-OTLP skip, 0 failures. Four adversarial and 175 targeted tests passed. [Evidence](evidence/continuous-capture-m0-m1.md#m1-repair-round-1). M2a recovery and scoped M2b/M2c controller/resource code passed fresh review; incomplete/legacy media and sustained/native qualification remain open. No unattended release approval. |
| M2 lifecycle/privacy | In progress; not complete | M2a and M2b1 accepted. M2b2 scoped physical boundaries/local close accepted after repair round 1. Scoped M2c resource enforcement also accepted. Effective unattended auto-start/lock authority and real-Mac/sustained qualification remain open. |
| M2a metadata/recovery | Accepted for scoped code criteria | Fresh review `4c984f95` passed with no repairs. Parent reran all six checks + build/test: 756 executed, 1 live-OTLP skip, 0 failures; 185 targeted tests passed. Pre-admission metadata, truthful closed interval and exact-once closed-claim/label/narration recovery; incomplete audio retained/blocked. Native qualification remains open. [Evidence](evidence/continuous-capture-m2a.md). |
| M2b1 intent/startup | Accepted for scoped code criteria | Fresh reviewer `75ecf7ee` passed without repairs; parent validation passed. Persisted Pause distinct from continuous preference; serialized/deferred startup gated on existing recovery; manual/continuous UI and reconnect/settings/workshop routing. Six checks + build/test pass: 772 executed, 1 live-OTLP skip, 0 failures; 22 focused tests pass. Conservative run guard requires explicit Resume after any recording/relaunch, even clean quit; seamless clean-quit auto-start is NOT accepted until M2b2 proves physical quiescence. [Evidence](evidence/continuous-capture-m2b1.md). |
| M2b2 physical boundaries/local close | Accepted for scoped code criteria; repair 1/3 | Input/SCK/AX/microphone fences, actual-return ownership, off-main truthful narration close, five-second controller drain and current-generation physical clean-quit restoration. Review repair 1 addresses independent AAC/PCM eligibility/UI ownership and settled label-task retirement after Pause. 77 targeted tests; six checks + build/test pass: 794 tests, one live skip, zero failures. Fresh reviewer `0e2ff636` passed the repair without further findings; parent reran required verification. Effective unattended auto-start remains blocked by unqualified OS lock/startup eligibility; current interactive acknowledgment required at launch/after suspension. No native qualification or full M2 acceptance. [Evidence](evidence/continuous-capture-m2b2.md). |
| M2c local disk reserve | Accepted for scoped code criteria; repair 1/3 | Configurable positive-byte reserve (initial engineering default 2 GiB, not qualified), fresh native archive/spool volume probes, admission/periodic environment suspension and M2b2 retained bounded close. Fresh reviewer `66663b05` passed the prospective-delivery-policy repair. Eleven new resource tests plus sealed-media ENOSPC recovery; parent six validators and build/test pass: 805 tests, one expected live skip, zero failures. No eviction, automatic Resume, finalization/enqueue authority or unattended OS eligibility change. [Evidence](evidence/continuous-capture-m2c.md). Real-Mac/sustained qualification and full M1/M2 remain open. |
| M3 authorization ADR | Proposed document reviewed; activation blocked | [ADR 0005](adr/0005-company-recording-policy.md) specifies policy, snapshot, immutable authorization, revision and publication fences. [Evidence](evidence/continuous-capture-m3.md). No source/wire changes or activation authority; current explicit confirmation rule still governs. |
| M4 deployment/setup | M4a scoped code accepted; repair 1/3 | Review-only Settings/first-run readiness, durable notice/history and native managed restrictions; see [evidence](evidence/continuous-capture-m4a.md). Full managed company-policy integration, native qualification and automatic authorization remain open. |
| M5 splitting | Pending | Safe time/size boundaries and resource tests, then real-Mac qualification. |
| M6 server migration | Blocked | Requires coordinated approved replacement for confirmation-only authorization. |
| M7 automatic delivery | Blocked | Requires M3/M6 and valid negotiated company authority; no synthetic human confirmation. |
| M8 integration/rollout | Pending | All applicable CI, authenticated integration and overnight/multi-day real-Mac trials must pass. |

Every substantial milestone gets one writer and a fresh-context reviewer. At most
three repair rounds per milestone; unresolved findings are checkpointed, not waived.
Record commands, exit codes, regression-before/fix-after evidence, review findings and
remaining gates here or in linked evidence notes. A running/waiting child is not a
completed milestone; this mission stays open until all acceptance criteria pass.

Status grouping is the existing completed slice. Work in small reviewable commits/PRs; preserve the installed
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

- [x] Capture repository/build/test baselines without changing real capture data.
  Evidence: baseline 732 tests executed, one skip; six contract checks/build passed.
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

The checked items here mean accepted **scoped code**, not full M2/native acceptance.

- [x] M2b1 separates continuous preference, persisted Pause and runtime startup intent;
  manual Start does not authorize relaunch/reconnect. M4 first-run/managed policy remains open.
- [x] M2b1/M2b2 serialize recovery/start/retained bounded close, persist intent before awaits
  and recheck production admission/ownership seams. M2c adds prospective-policy disk probes.
- [x] M2b2 fences requests/results and stops both audio producers before advisory drain;
  executable workspace signals plus conservative interactive acknowledgment fail closed.
- [x] M2b1/M2b2 route menu/settings/reconnect/startup through the intent/eligibility owner,
  with mode-appropriate controls and truthful physical microphone/closing/blocked status.
- [ ] Qualify authoritative OS-unlocked/startup eligibility and real-Mac privacy/stop races;
  current interactive acknowledgment is not unattended authority. First-run readiness is M4.

**Exit:** reconnect/relaunch cannot undo Pause; Stop during startup never enables input;
privacy-crossing frames are rejected; source shutdown and recovery races pass. Keep
review-only upload unchanged. Real-Mac OS boundary checks are required before release.

#### M2a — Metadata/recovery scoped implementation accepted

- [x] Persist source/capture/artifact/label/privacy/modality and admission context before
  recorder admission; preserve the original label-start declaration if its async task is lost.
- [x] Persist the reported-active start/native stop and verified closed-file identity before
  seal/ingest; retry closed recording/sealed/admission-failed claims without guessed metadata.
- [x] Bind receipts to trusted archive ownership and immutable WAL/checkpoint intent;
  prove publication before consuming source media. Retain/block genuinely incomplete audio.
- [x] Reproduce seal-before-intent/admission-failed recovery failures before implementation;
  check after-fix exact-once restart, truthful intervals, tampering, foreign claims, fsync faults
  and actual child-process SIGKILL boundaries. [Commands/results](evidence/continuous-capture-m2a.md).
- [x] Fresh independent review `4c984f95`; parent acceptance of this slice (not full M1/M2).
- [x] Scoped M2b lifecycle/physical privacy and M2c reserve code accepted as recorded below.
- [ ] Real-Mac and sustained qualification; full M1/M2 acceptance remains open.

#### M2b1 — Persisted intent/startup scoped implementation accepted

- [x] Separate continuous preference, persisted user Pause and a fail-closed startup guard;
  manual Start never authorizes automatic start after reconnect/relaunch.
- [x] Claim starts before Task scheduling; await existing M2a recovery completion, recheck intent
  after preparation and immediately before enabling sources; Stop/Pause wins over pending startup.
- [x] Route menu/settings/launch/reconnect through this eligibility owner; cancel pending workshop
  startup/late capability handoff without opening a new microphone label.
- [x] Deferred/fake startup/recovery and failed-storage tests; all six contract checks plus Swift
  build/test pass. [Commands, results and qualifications](evidence/continuous-capture-m2b1.md).
- [x] Fresh review `75ecf7ee` and parent scoped acceptance. Full M2 remains open.
- [x] M2b2 implementation/checks below replace the interim `sourcesWereEnabled` prohibition with
  closed-gate actual-return proof; no unattended OS eligibility is inferred from that proof.
- [x] Scoped M2c capacity/reserve code accepted after repair round 1/3.
- [ ] Real-Mac/sustained qualification; no unattended deployment approval.

#### M2b2 — Physical boundaries and bounded close scoped code accepted

- [x] Synchronous input/SCK/AX/microphone revocation; per-read/per-await native admission/result
  fences; keep physically outstanding work and exclusive owners after logical timeout.
- [x] Stop both audio producers before advisory drains; persist M2a truthful close off MainActor,
  retain failed/incomplete claims and surface actual native recording/finalizing/blocked UI.
- [x] Bound the complete controller local-close sequence, cancelled startup and label settlement;
  prevent late completion from authorizing another capture or replacing current user Pause.
- [x] Restore the continuous clean-quit **physical/intent guard** only after actual quiescence and
  settled close. Manual mode never auto-starts; user Pause remains persisted and independent of
  environment suspension. Deferred production-adapter/runtime checks and all required commands pass.
- [x] Executable workspace sleep/screens/session signals and conservative lock hints; unknown state
  fails closed. Current interactive acknowledgment plus public session/permission checks is the
  supervisor-approved conservative boundary, not authoritative proof of unlocked state.
- [x] Review repair 1: retain potentially active ownership across both microphone producers even
  when AAC stops unexpectedly; stop both on permission loss without changing original media.
  Retire settled label-close tasks independently of stale-generation reopening permission; preserve
  newer owners and failed/timeout blockers. Four regression tests, 77 targeted checks and 794 full
  tests (one expected live skip) pass; six validators/build pass. Production orchestration seams only,
  not full native controller/TCC qualification. Fresh repair reviewer `0e2ff636` passed with no
  further findings; parent reran verification and accepted this scoped slice.
- [ ] Effective unattended clean-quit startup/environment recovery remains blocked at OS eligibility.
  Wake/active/unlock hints alone cannot establish a non-lock classification or erase Pause.
- [x] Fresh independent review/parent scoped acceptance; M2c resources accepted below.
- [ ] Real-Mac lock/sleep/session/TCC/native-stop latency and sustained qualification.
  [Exact checks, supported signals and residuals](evidence/continuous-capture-m2b2.md).

#### M2c — Disk/resource admission scoped code accepted

- [x] Configurable validated local reserve, initial engineering default 2 GiB only; pure Foundation
  checked capacity arithmetic and executable native probes on actual archive/spool destination volumes.
  Missing, invalid, failed and stale capacity fails closed without a cached-success bypass.
- [x] Check before Start/archive/source/label/narration admission and through the existing active
  capability timer; resource failure revokes the environment and uses M2b2 bounded retained close.
  No synthetic Pause/confirmation, automatic Resume, quota eviction or M1 task-limit rewrite.
- [x] Account known screenshot/sealed-copy sizes after producer return without discarding their
  outcomes or rescanning inventories. Existing claims, canonical bytes and delivery packages remain
  retained; concurrent-fill ENOSPC and recovery-required handling remain authoritative.
- [x] Eleven new decision/production-seam tests after prospective-delivery-policy repair, plus
  existing sealed-media recovery extended with ENOSPC; parent six validators and Swift build/test
  pass: **805 tests, one expected live skip, zero failures**.
  [Exact scope, checks and residuals](evidence/continuous-capture-m2c.md).
- [x] Fresh repair reviewer `66663b05` passed with no further findings; parent accepted this scoped
  slice after repair round 1/3. Reserve checks use the prospective frozen delivery policy.
- [ ] Native volume/latency/ENOSPC and sustained/overnight reserve qualification. The engineering
  default is not a proven operating threshold; full M1/M2 and unattended OS eligibility remain open.

### M3 — Specify and approve company policy authorization

**Can be drafted alongside M1/M2; blocks automatic-upload code, not safety fixes.**

The checked items below are **draft specification only**, not accepted policy or implementation.

- [x] Draft [ADR 0005](adr/0005-company-recording-policy.md), status PROPOSED; accepted ADR 0003
  and governing requirements remain unchanged.
- [x] Propose company-admin authority, precedence, generations/expiry/refresh and independent
  modes; select a separate signed policy reusing enrollment trust, not a second key framework.
- [x] Specify capture-start snapshot, external per-archive binding and fresh attempt checks;
  use the actual inventory → manifest digest → exact ZIP pipeline without a hash cycle.
- [x] Specify generation cutoff/60-second grants and transactional READY/outbox fencing;
  retain local data and prohibit retroactive backlog release.
- [x] Choose a genuine human-reviewed new revision for an already sealed automatic archive
  held after policy change; never modify queue-owned bytes or fabricate a correction/confirm.
- [ ] Review and approve the exact schema/API semantics before implementing the second
  delivery path. Company authorization remains distinct from human evidence approval.

**Exit:** the ADR resolves the decisions below, includes positive/negative fixtures and
migration behavior, and the governing confirmation-only rule has an explicitly approved
coordinated replacement. Until then automatic-upload choices are unavailable, not fake.

### M4 — Deployment configuration and first-run setup

**Desktop seams:** `JazzCapture/Settings.swift`, `SettingsView.swift`, `AppDelegate.swift`,
`JazzEnrollmentSecurity/` trust/acceptance code, and `macos/README.md`/release tooling.

**Current M4a slice, independent of blocked automatic upload:** review-only setup readiness
implemented below, awaiting fresh review.
Show verified enrollment company/Area/destination and trust/profile status (including MVP versus
production device-bound enrollment), missing trust/identity/permissions and a clear remedy. Persist
truthful notice/setup readiness separately from Pause and capture policy. Test clean install,
upgrade, denied permissions, missing enrollment, relaunch and profile removal with temporary roots
and fake boundaries. Reuse Settings/first-run UI; no custom installer, new signing authority,
policy-v1 network implementation or login registration in this slice. A Ready setup screen must
not claim Secure Enclave/native/TCC qualification or erase the current interactive OS acknowledgment.
Automatic upload stays unavailable until governing approval and M6/M7 negotiation; login startup
and unattended OS authority remain separate gates. This narrows M4's next slice, not full acceptance.

#### M4a — Review-only deployment/setup readiness (scoped code accepted; repair 1/3)

- [x] Reuse one Settings/first-run readiness view; honest company/Area/destination, enrollment
  acceptance/profile, requested mode, modalities, permission remedies and visibly unavailable
  automatic company upload. Older signed installations do not invent device-bound activation proof.
- [x] Independent durable notice receipts and managed/enrolled history; no capture-timestamp consent
  inference, Pause clearing, archive confirmation or backlog release. Corrupt/failed storage blocks.
- [x] Native forced preferences narrow recording/modalities and require review/enrollment; malformed
  or removed profiles block and forced fields are locked. Explicit never-managed local-only offline
  setup remains available without network authority. Deployment knobs/limits documented in macOS README.
- [x] Gate requestStart, post-await source admission and settings/credential transitions through the
  tested readiness seam; retain CaptureStartIntent, physical/resource fences and bounded local close.
- [x] Repair review-0's three P1 defects: allow local-only OFF after enrollment/managed arrival;
  synchronize all notice-bound Settings controls without preference writeback; distinguish unknown
  evidence reads from positive enrollment history. Six new injected production-store/read-boundary
  regressions pass; 69 focused checks and 832 full tests (one expected skip), six validators/build pass.
- [x] Fresh repair reviewer `d5640c5e` passed; parent reran six validators/build/test:
  832 tests, one expected skip, zero failures. Scoped code accepted; checks/results in the
  [M4a evidence](evidence/continuous-capture-m4a.md).
- [ ] Installed first-run/MDM/TCC/Secure Enclave/native startup-stop and latency qualification.
  Current interactive-only OS gate remains unchanged; no unattended activation claim.

The full-M4 company-policy integration items below are not implied by this review-only slice:

- [ ] Resolve managed policy over permitted local preferences; invalid or removed
  policy cannot relax review requirements. Restrict managed fields in Settings.
- [ ] Extend the shared M4a Recording and upload view to approved company-policy modes,
  only after M3/M6 gates. Review-only view and independent notice/Pause persistence are
  implemented above; no capture-start timestamp manufactures renewed human consent.
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
