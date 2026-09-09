# Continuous capture M2b1 — intent and startup eligibility

Baseline: `589018f`. Scoped code criteria accepted after fresh review `75ecf7ee`;
native qualification remains pending. **Not full M2, not unattended-release approval.** No emitted contract/confirmation change.

## Implemented boundary

- `CaptureStartIntent` is the Foundation-only owner of persisted user Pause, a durable run guard,
  recovery readiness and synchronous startup generations. Continuous mode remains a separate
  preference. Manual Start is process-local; automatic requests never authorize manual capture.
- `CaptureController.requestStart` claims the slot before scheduling its Task. The shared
  `runStart` awaits the existing M2a recovery task, then preparation, then checks current intent
  immediately before synchronous source enable. Pause/Stop and mode-off invalidate intent before
  persistence/drain. Cancelled preparation retains/commits its local archive or blocks for recovery.
  Preparation/write/close failures cannot silently admit a sibling start.
- Launch/reconnect/settings call the automatic path, never explicit Resume. Menu labels distinguish
  manual Start/Stop, continuous Pause/Resume, pending workshop cancellation and finalizing. Turning
  continuous mode off stops current/pending capture; turning it on does not erase Pause.
- Caller trace: AppDelegate toggle, launch/reconnect callback, settings notification, workshop
  callback and quit; controller admission-failure path; BDM `start`/`finish`. BDM capability results
  are generation-checked, repeated workshop starts serialize, and cancelled late success cannot
  open a panel or microphone label. GuidedExecutionPanel uses a different controller, unchanged.
- Prior M2a archive recovery algorithm, metadata/claims and emitted records are unchanged; only
  its completion/failure is now the start gate. Successful native startup still installs the tap,
  app observer and timer; microphone admission remains label-scoped.

## Deliberate fail-closed limitation (supervisor approved)

The local `capture-intent.json` run guard is atomically written and file/directory synchronized
**before any startup admission**. A failed Pause write cannot leave old unpaused bytes authorizing
automatic capture: the previously committed guard still requires explicit Resume. Corrupt/unreadable
intent or synchronization failure blocks admission; the UI surfaces storage failure.

**Clean-quit continuous auto-start after recording is NOT implemented/accepted in M2b1.** Existing
logical drain does not prove physical ScreenCaptureKit quiescence. Once sources were enabled, even
clean quit retains the guard; next launch requires explicit Resume. The UI calls this a safety check,
not a user-requested Pause. Only positively settled pre-source cancellation/idle shutdown can clear
the guard, and only for the current unchanged intent generation. Timeouts, failed recovery/close,
manual mode and a later Pause cannot restore eligibility. M2b2 must remove this interim limitation
with real physical quiescence proof; it is not the desired final continuous-mode product behavior.

## Checks

Logs: `/tmp/jazz-continuous-eaa688eb/m2b1/` (full logs stay outside Git).

| Command | Exit / result | Log |
| --- | --- | --- |
| `uv run --script contract/validate_schemas.py` | 0 | `validate_schemas.log` |
| `uv run --script contract/archive/validate_archives.py` | 0 | `validate_archives.log` |
| `uv run --script contract/live/validate_live_transport.py` | 0 | `validate_live_transport.log` |
| `uv run --script contract/live/validate_capture_coach_live.py` | 0 | `validate_capture_coach_live.log` |
| `uv run --script contract/live/generate_capture_coach_fixtures.py --check` | 0 | `generate_capture_coach_fixtures.log` |
| `uv run --script contract/archive/container/generate_fixtures.py --check` | 0 | `generate_fixtures.log` |
| `cd macos && swift test --filter 'CaptureStartIntentTests\|AutoStartTests\|BdmWorkshopStartupTests'` | 0; 22 tests, 0 failures | `focused.log` |
| `cd macos && swift build` | 0 | `swift-build.log` |
| `cd macos && swift test` | 0; 772 executed, 1 live-OTLP skip, 0 failures | `swift-test.log` |
| `git diff --check` | 0 | reviewer bundle verification |

Added 14 Foundation tests and 2 executable workshop tests. Deferred recovery/preparation/abort
prove ordering, Pause before Task execution/during awaits, repeated Start exclusion through cleanup,
recovery failure, explicit Resume, persisted Pause/reconnect, manual-mode exclusion, mode change,
corrupt intent, failed synchronization, old durable bytes after a failed Pause write, and stale/
unsettled/physically-unqualified shutdown restoration. The Foundation tests exercise the **same
async orchestration invoked by the controller**, not OS adapters. Workshop tests exercise the actual
executable controller with deferred callbacks and never show a panel or enable a microphone.

No full native CaptureController/TCC integration test or before-fix native reproduction was run.
No real recordings, credentials, live APIs, installed app, AGENTS, confirmation policy, or Git index
were changed. The live OTLP test remained skipped because no endpoint was configured.

## Parent verification and budget checkpoint

Parent inspected the intent owner and controller/AppDelegate/workshop integration, then
reran all six required contract validators and `swift build && swift test`: all exit 0;
**772 tests executed, one environment-gated live-OTLP skip, zero failures**.
`git diff --check` passed. Log: `/tmp/jazz-continuous-eaa688eb/m2b1/parent-validation.log`.
This is not a fresh independent review and does not accept M2b1 for publication/deployment.

Detached writer `6510148e` completed its implementation handoff with exit 0; the harness
reported acceptance rejected. Parent recovered the output and verified commands rather
than treating the wrapper state as a passing review. Fresh review did not run because
parent workflow `b9aca7aa-7a43-4f14-931d-a8588b34ce87` detached at supervisor coordination.

Summing assistant input/output usage in the retained child session gives **86,584 input +
29,842 output = 116,426 tokens**. Added to 701,197: **817,623 / 800,000**, an overrun of
**17,623**. The configured launch budget does not interrupt an already-running child and
native accounting missed the detached debit. No review/repair child has been launched after
recovering this exhausted balance. Work remains uncommitted, unstaged and preserved.

Next ready action: obtain additional authorized review/implementation budget, launch a fresh
read-only M2b1 review against `589018f`, repair concrete findings (maximum three rounds),
then parent accepts/commits/pushes and continues M2b2. Do not resume the historical paused
workflow as a competing writer. PR #33 still has passing CI but requires repository review;
PR #35 remains draft at accepted M2a `589018f`. No merge or installed-app deployment.

## Resumption and scoped acceptance

User authorized another 800,000 tokens after the checkpoint above, for **1,600,000 cumulative**.
Fresh reviewer `75ecf7ee` read the complete phase diff and affected callers/tests and returned
**PASS, no required repairs**. Review artifact: `/tmp/jazz-continuous-eaa688eb/m2b1/review-0.md`.
The earlier parent validation is for this same unchanged code: all six checks/build/test pass,
772 executed, one live skip, zero failures. Review does not claim native execution or approve
clean-quit auto-start, full M2b2, or unattended release.

Review workflow `7b633d6f-f438-4010-a2c5-33822d80c5e5` used **73,508 input + 3,132 output =
76,640 tokens**. Cumulative **894,263 / 1,600,000 used; 705,737 remain** before M2b2.
Parent accepts the scoped code, commits/pushes, then continues physical fences/bounded drain.

## Remaining gates

- M2b2: full bounded controller drain, physical input/result fences, OS lock/sleep/session signals,
  actual microphone-state UI, and proven quiescence before clean-quit auto-start eligibility.
- M2c resources/reserve; time/idle rotation, automatic/company delivery and live qualification remain
  outside this slice. No unattended deployment until the remaining lifecycle/privacy gates pass.
