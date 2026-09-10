# M5b1 — idle-triggered local close, explicit restart only

Baseline `2fec864`. Implemented and verified by the **main agent only**, following the user's
updated execution instruction. No subagents or panel were used; no new independent-review claim.
This is a scoped close-only increment, **not full continuous idle/activity resumption**.

## Behavior

- Reuses `CaptureChunkBoundary`, the existing one-second timer and `CaptureSourceEnvironment`'s
  synchronous revocation/close owner. No additional input listener, timer task queue or recorder.
- The native adapter queries `CGEventSourceSecondsSinceLastEventType` for HID state and
  `kCGAnyInputEventType` (not a null event). The local SDK header documents keyboard/mouse/tablet
  age. Swift representation was type-checked and checked without executing an input query.
- Default idle threshold is five minutes. String preference `captureIdleSeconds.v1` permits
  60–300 seconds; missing uses 300, malformed/wrong-type/out-of-range values block. No installed
  preferences were changed. This engineering tuning is not yet native-qualified.
- The interval begins at the original interactive acknowledgment, not each new chunk. Short
  time/size rotations cannot indefinitely postpone idle closure. Explicit later Start/Resume gets
  a fresh interval, avoiding immediate closure from HID history predating that action.
- Idle is sampled during capture and rechecked across close/preparation before replacement
  source admission. It revokes live acknowledgment and disarms without setting user Pause.
  Reconnect, wake, unlock hints or new input do not automatically restart. Relaunch retains the
  existing fail-closed run guard. Menu/status identifies inactivity and explicit restart.
- Closes at detection through the normal journal/runtime path, never backdating to last input.
  Already-captured idle-tail observations and canonical data are retained; no ZIP finalization,
  confirmation, queue insertion, wire change or automatic upload authority is introduced.
- Open labels, narration, retained label closure and workshops defer idle detection. Time/byte,
  privacy, permissions and resource limits still apply. Workshop-owner notification now belongs
  to the shared environmental-stop path, covering invalid settings and other revocations too,
  without issuing a second capture Stop.

Input age is only a heuristic. Reading, calls, assistive/remote input and synthesized HID events
may not correspond to it. It never proves human presence or unlocked state. No automatic-resume
eligibility is inferred from a low age; the interactive OS gate remains intact.

## Main-agent verification

All six required contract validators/generators, `swift build`, `swift test` and `git diff --check`
passed: **853 tests, one expected live-OTLP skip, zero failures**. The focused run passed **53 tests**.
Five new tests cover equality/invalid values, original acknowledgment versus short rotations,
span deferral, idle during closing/preparation in both modes, canonical close without approval,
relaunch guard, explicit restart, and stored-setting type handling. They exercise Foundation and
real executable owners with injected clocks/input/native-source boundaries and temporary roots.
They do not instantiate native AppDelegate/CaptureController or qualify installed input/timer UI.
Main-agent source inspection checked the actual controller timer/start/rotation and workshop wiring.

Logs: `/tmp/jazz-continuous-eaa688eb/m5b1/{focused.log,validation.log,validation.exit}`;
`validate.sh` uses top-level fail-fast commands, not a conditional brace group that masks failures.
Native enum/API compile-only check: `idle-api-typecheck.swift`. No real Keychain, capture sources,
recordings, installed settings or running app were altered. Installed version 0.25.0 was observed
running on macOS 26.5.2; this is not evidence that its recording was idle or safe to interrupt.

## Budget and remaining work

User renewed authorization by 1,500,000: **4,700,000 total**. Historical child-only debit remains
2,996,143. With main-agent-only execution, new reported main input/output is counted from the
renewal message rather than leaving the old child counter unchanged indefinitely. Snapshot through
parent entry `73aa9fdd`: main 201,011 input + 21,099 output; combined **3,218,253 used,
1,481,747 remaining at that snapshot**, excluding cache reads. Later parent work is additional;
`/tmp/jazz-continuous-eaa688eb/main-budget-check.py` recomputes the exact bounded ledger.

No fresh independent review or native qualification is claimed. Repository review, native pilot,
real input/lock/sleep/audio/menu timing, sustained behavior and final authenticated integration remain
open. Automatic idle/activity resumption and M6/M7 automatic delivery remain separate gated work;
ADR 0005 is still proposed and archive-level confirmation still governs delivery.
