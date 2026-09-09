# Continuous capture M2b2 — physical boundaries and bounded local close

Baseline: `62a58e5`, branch `feat/company-recording-policy`. **Scoped code accepted after
fresh repair review round 1/3. Not full M2 or unattended-release approval.**
Parent owns commit/push; no deployment, real recording, credential or live-network test.
No contract fields, delivery/confirmation policy, AGENTS or authorization changes.

## Implemented boundaries

- Stop/Pause, cancelled startup, admission failure, shutdown and environment suspension close
  input, screenshot and microphone admission synchronously before awaited cleanup. EventTap
  seals its callback gate, disables/invalidates its port and resolves previously completed
  pointer observations. Pending input does not authorize new pixels or microphone admission.
- ScreenCaptureSingleFlight is now a MainActor, generation-scoped gate. Closing is synchronous;
  opening requires a closed, physically empty slot. Queued old tokens stay invalid after reopen.
  The slot survives logical deadline/cancellation until actual native return. All **three**
  controller callers carry admission captured with the observation, not a fresh late token.
  The production adapter checks scheduled admission, content-enumeration return, frame admission,
  frame return and pre-JPEG/publication eligibility. Late frames never reach JPEG/hash/publication.
- The adjacent AX seam was explicitly approved by the supervisor during implementation. Both
  asynchronous enrichment callers now use the same queued AX adapter; keyboard focus also carries
  its capture gate. Per-generation leases fence queued work, each attribute/hit-test/PID/window-list
  read, traversal continuation, main-thread fallback and results. Actual utility/fallback/native-read
  return participates in close proof. No lock is held across blocking AX IPC. Revocation cannot
  interrupt an already-admitted native call, but rejects its result and every subsequent read.
  Existing guided-execution AX policy remains separate and unchanged.
- Narration stops the PCM tap/engine **and** AVAudioRecorder before advisory drain. The observed
  native-stop timestamp still feeds the M2a verified-close callback. Container probe, receipt
  persistence and claim sealing are off MainActor and retain their original claim ownership.
  Blocked PCM cannot extend AAC recording or suppress its close receipt. Failed/incomplete audio
  remains retained/recovery-required; UI reports native recording, unknown/potentially active,
  off/finalizing or retained error, not merely an open logical label. Both producer handles retain
  microphone eligibility/UI ownership until both synchronous stops return, independent of AAC's
  reported state. No reconstruction, guessed interval or deletion was added.
- The actual controller pre-commit sequence is `CaptureLocalClose.drain`: native drains, Coach
  label/audio/live tails, journal admissions/producers, Coach actions, ordered local projection,
  screen/AX quiescence, then canonical close. A five-second owner bounds the entire awaited
  sequence, not just runtime.close. Startup cancellation and label close also use this owner.
  Deadline/error is terminal recovery-required; late completion cannot change it to settled.
  The existing runtime recovery fence is now callable when the controller deadline expires before
  runtime.close. Exclusive owners/claims remain retained; cancellation is never ownership release.
- Label changes briefly fence input/context/pixels while native and local work settles; an explicit
  existing gap records that omission. A pending next-label request is generation-checked and cannot
  reopen after Pause. Label/session source gates reopen only after actual return and current
  eligibility. A timed-out close blocks another capture even if the physical task later returns.
  Already-admitted PCM callbacks retain their durable tail after timeout; no new callback is admitted.
- The M2b1 `sourcesWereEnabled` prohibition is removed. **Physical/intent-layer** clean-quit
  restoration now requires closed screen/AX gates, actual microphone quiescence, settled local close,
  current intent generation, recovery readiness and continuous/unpaused intent. Pause beats stale
  completion; manual mode never auto-starts. This does not bypass the OS gate below.

## Supported native signals and explicit remaining qualification

Executable-only integration listens to NSWorkspace willSleep/didWake, screensDidSleep/
 screensDidWake and sessionDidResignActive/sessionDidBecomeActive notifications. Public CGSession
`onConsole`, `loginDone` and current-user `userID` keys are preflight membership checks. Unknown/missing state fails closed.
Distributed `com.apple.screenIsLocked` is a **negative hint**, not authoritative lock attestation;
`screenIsUnlocked`, wake and active signals never prove unlocked or clear suspension/Pause.

Supervisor-approved conservative boundary: **every launch and every negative environment signal
requires a current interactive Start/Resume acknowledgment**, plus current public session membership
and permission checks. That action is not represented as proof of an authoritative unlocked API.
Environment suspension never persists ordinary user Pause. Persisted user Pause survives wake,
reconnect and relaunch. No non-lock automatic-recovery classification is invented from missing hints.

**Remaining product/code activation:** effective unattended clean-quit auto-start/environment resume
is deliberately blocked at OS eligibility, even when the physical run guard was cleanly restored.
This is separate from the implemented physical-settlement criterion. Authoritative lock/startup
eligibility and real-Mac qualification remain unmet; this phase must not be called full M2 completion.
Notification delivery/preflight visibility is not zero-latency interruption. Permissions are checked
at input/start/media admissions and by the existing three-second timer (best effort on MainActor).
Already-admitted blocking native calls may return late; gates remain closed and results are discarded.
Real-Mac sleep/lock/session/TCC/audio interruption, synchronous native-stop latency, resource and
long-capture qualification are still required. No tests manipulated the user's session or installed app.

## Checks and raw evidence

All raw artifacts are under `/tmp/jazz-continuous-eaa688eb/m2b2/` outside Git.

| Check | Result / artifact |
| --- | --- |
| Baseline clean-quit intent regression | Exit 1; one test, two expected assertions: `regression-before.log` |
| Same restored-intent expectation with explicit physical proof | Exit 0: `regression-after.log` |
| Pre-review adapter/close/intent/runtime/input targeted suite | Exit 0; 73 tests, zero failures: `targeted-final.log` |
| Pre-review all six AGENTS contract commands | All exit 0: individual validator/generator logs; `command-exits.txt` |
| Pre-review `cd macos && swift build && swift test` | Both exit 0; **790 tests, one expected live-OTLP skip, zero failures**: `swift-build.log`, `swift-test.log` |
| Diff whitespace and index | `git diff --check` passes; no staged paths: `caller-and-index-check.log`, `git-check.log` |

Final commands are the six unchanged AGENTS commands, then Swift build/test; the exact command
list/exits are in `command-exits.txt` and runnable `run-validation.sh`. `full-validation.log` summarizes
those separate full logs. `JAZZ_LIVE_OTLP_ENDPOINT` was unset; no live endpoint was configured.

Deferred checks exercise **production** ScreenCapture prepare/frame/encode, AX utility/read/fallback,
Narration physical-stop/finalization/drain and the controller's actual local-close sequence with
synthetic temporary data. Coverage includes queued admission after reopen, revoke during native
awaits, no late JPEG/AX context, timeout-held physical ownership, both audio stops before a blocked
PCM drain, truthful failed audio close, each blocked local tail, lease exclusion/late-writer fencing,
user Pause/environment interplay, clean physical restoration and stale/unsettled rejection.
The baseline reproduction is the intent limitation; native adapter tests were added after refactoring
for injection, not run against old native hardware. Full CaptureController/AppDelegate/TCC integration
was not instantiated in tests; no unit result claims real native signal authority.

## Review repair 1 — independent audio ownership and settled label retirement

The first fresh review (`review-0.md`) requested P1 and P2 repairs. Only their production seams,
regressions and evidence were changed; other reviewed boundaries and original evidence remain intact.

- **P1:** retained Narration native handles represent potentially active ownership of **both** AAC
  and independent PCM. AAC inactivity alone cannot display an off/slashed microphone or skip the
  controller's microphone-permission predicate. Unknown ownership is explicit in the state text.
  Permission loss revokes the environment and synchronously stops both producers before off state;
  an unobserved AAC stop still fails finalization without inventing a receipt or changing original bytes.
- **P2:** the controller's label close and start-label paths now use `CaptureLabelClose` in the existing
  local-close source. A settled current owner retires its task **before** checking permission to reopen
  the old generation. Pause therefore cancels reopening without poisoning the next clean Resume.
  Identity guards prevent stale completion from retiring/reopening a newer owner; failure/deadline
  outcomes remain retained blockers, including after late physical return. Session close awaits this
  same owned task. No reset of timeout/recovery state or stale source reopening was introduced.
- The narrow orchestration seam was approved instead of adding controller initialization hooks that
  would start OS observers/background services. Tests exercise production label admission/retirement,
  `CaptureStartIntent` and `CaptureLocalClose`, not a full native controller session. The deferred test
  covers pending label drain → Pause → settled session close → explicit Resume → fresh label accepted,
  and rejects the stale label request. Separate checks cover stale owner and failure/timeout retention.
- The audio regression injects AAC inactive/PCM active, uses the exact controller permission predicate
  and production environment revocation, checks ownership during both synchronous stops, then proves
  failure retention and byte-identical original synthetic media. No real microphone/TCC revocation,
  installed-app session or genuine AAC container was exercised.

| Repair check | Result / artifact |
| --- | --- |
| Before-fix reproduction | Exit 1; four tests, six expected assertion failures: `repair-regression-before.log`. Run after extracting the production seams while retaining the original AAC-only predicate and reopen-success-only retirement; not a native baseline run. |
| Same regression suite after fixes | Exit 0; four tests, zero failures: `repair-regression-after.log` |
| Expanded targeted suite | Exit 0; **77 tests, zero failures**: `repair-targeted.log` |
| Six unchanged AGENTS contract commands | All exit 0: `repair-command-exits.txt`, `repair-validate_*.log`, `repair-generate_*.log` |
| Swift build/full tests | Both exit 0; **794 tests, one expected live-OTLP skip, zero failures**: `repair-swift-build.log`, `repair-swift-test.log` |
| Whitespace/index and bounded caller audit | `repair-git-check.log`; no staged paths; no Git/index mutations |

Exact repair commands: `run-repair-validation.sh`; aggregate output: `repair-full-validation.log`.
`pre-repair/tree/`, `pre-repair/tracked.diff` and `pre-repair/status.txt` preserve the prior work.
`repair-delta.diff` includes only this repair (including its new test); `repair-changed-files.txt` and
`repair-diff-stat.txt` scope that delta. Original pre-review logs are preserved. Real-Mac signal,
permission and native-stop qualification, authoritative startup/lock eligibility and M2c remain open.

Reviewer bundle: `phase.diff` against `62a58e5` **including new files**, `changed-files.txt` and
`diff-stat.txt`. Fresh repair reviewer `0e2ff636` returned **PASS** with no further defects.
Review artifact: `repair-review-1.md`. Parent inspected source environment/local-close ownership
and reran all six required validators plus build/test: **794 executed, one expected live skip,
zero failures** (`parent-repair-validation.log`). `git diff --check` passed.
Parent accepts the scoped M2b2 code after repair round 1/3; no unattended/native approval.

Budget debits: writer `b06a3172` 159,099 input + 66,015 output = 225,114;
review `1331e8a3` 81,123 + 4,031 = 85,154; repair `949ca722` 97,827 + 14,957 = 112,784;
fresh repair review `0e2ff636` 42,096 + 2,107 = 44,203. Including prior 894,263:
**1,361,518 / 1,600,000 used; 238,482 remain**. Detached debits are recovered from
retained sessions; native zero is not authoritative.
Next: commit/push accepted code, then M2c disk/resource enforcement and remaining milestones.
No installed-app deployment; real-Mac/native eligibility gates above remain open.
