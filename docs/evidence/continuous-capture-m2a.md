# Continuous capture M2a — durable narration admission and closed recovery

Date: 2026-09-09. Branch: `feat/company-recording-policy`; code baseline: `992bd47`.
**Implemented and checked; independent review pending. Full M1/M2 and real-Mac
qualification remain open.** No commit, staging, deployment, automatic delivery,
contract-field changes, credentials, real recordings or installed-app changes.
The resumed budget/mission edits already present in the plan were preserved.

## Change and boundaries

- `NarrationRecorder.start` synchronously persists admission metadata before constructing
  or enabling `AVAudioRecorder`. Failure prevents admission and never deletes the claim.
  The receipt stores archive/capture/artifact/observation/source/actor/stream identities,
  explicit narration modality/privacy policy, label/process context, admission timestamp,
  and original label-start identity/extensions. The label-start admission is asynchronous;
  preserving its declaration avoids inventing it if that task never reached the WAL.
- Immutable local receipts are under
  `.artifact-contexts/<archive>/<capture>/<artifact>.start.json` and `.closed.json`.
  They supplement the existing writable claim, journal WAL/checkpoint and exclusive
  recovery owner; they are not archive wire fields or a second capture/delivery service.
  Claim files and directory chains are synchronized before admission. Close receipts bind
  the admission digest, actual reported-active start, native stop, exact fingerprint and
  filesystem snapshot of the closed media; their content checksum is validated on read.
- Admission time is **not** exported as audio start. The start sampled after the native
  recorder reports recording and the end sampled at native stop form the artifact and
  narration interval. Tests deliberately separate admission and actual start by three
  seconds. No filesystem mtime, relaunch time or guessed container duration supplies an end.
- Every controller stop call, including admission-failure shutdown, invokes the same
  recorder-owned close callback. It requires the recorder still to be active at stop and
  `AVAudioFile` to open a nonempty closed container. Probing remains in the executable;
  no repair, re-encoding or original-byte replacement is performed. The existing advisory
  PCM drain order remains unchanged; this is not M2b physical-source fencing.
- Recovery validates receipt filename/path/identity, source/actor/policy/modality, timestamp
  ordering, admission/close binding, and matching WAL/checkpoint artifact and observation
  intent. Existing descriptor ownership, lease/revocation, immutable intent and canonical
  publication-before-deletion checks remain in force. A closed `.recording.m4a` can be
  verified and renamed; a rename/seal interrupted before ingestion can be resumed.
  Missing intents are checkpointed before publication with stable observation IDs.
  Repeated recovery publishes one artifact and one narration/label-start observation each.
  Receipts remain as local replay bindings after media consumption. Integrity checks do
  not claim cryptographic attestation against coherent replacement of all local evidence.

## Checks and raw evidence

Raw logs: `/tmp/jazz-continuous-eaa688eb/m2a/` (outside Git).

| Check | Result / log |
| --- | --- |
| Before implementation: seal-before-intent and admission-failed closed claims | Exit 1, 2 expected retained-claim errors: `regression-before.log` |
| Same recovery expectations after adding required admission/close persistence to setup | Exit 0, 2 tests: `regression-after-first.log` |
| Final journal/archive/native admission targeted run | Exit 0, 185 tests, no failures: `targeted-final.log` |
| All six AGENTS contract commands, then `swift build && swift test` | Every command exit 0; 756 tests, 1 expected live-OTLP skip, no failures: `full-validation.log`, `command-exits.txt` |
| Diff whitespace and no staged paths | Exit 0; no staged entries: `git-check.log` |

Regression names: `testNarrationSealBeforeIntentRecovery` and
`testNarrationAdmissionFailedClosedRecovery`. Baseline setup used the old claim-only
API; fixed setup adds the new durable boundary calls before exercising the same crash
and recovery assertions. The original failure is not waived by accepting blocked output.

Additional executable checks (all synthetic files in temporary roots):

- `testNarrationIncompleteCrashBoundariesNeverInventClosedAudio`: before metadata,
  admission-only, recording, sealed-without-stop, and native-stop-before-receipt remain
  blocked with unchanged bytes and no fabricated artifact.
- `testNarrationClosedCrashEdgesReplayExactlyOnce`: durable stop before seal; after
  rename; seal fsync failure; reserved/staged work; ingest WAL; canonical publication
  before resolution acknowledgement; recovery checkpoint fsync failure. Restart again,
  check bytes/intervals/counts and commit through the existing interrupted-recovery path.
- `testNarrationReceiptsRejectTamperingAndForeignClaimsWithoutDeletingBytes`: label/time
  changes, independently rebound foreign source/claim, changed/reversed closed interval,
  altered audio, symlink receipt, and unconsented modality.
- `testNarrationReceiptBindsWALAndCheckpointIntents`: replace a valid ingest interval
  in WAL or checkpoint; fail before publication/checkpoint replacement/deletion.
- `testNarrationRuntimeUsesAdmissionIdentityAndRejectsMetadataSubstitution`: normal
  runtime publication/commit/reopen with actual-start offset and rejected forged record.
- `testNarrationAdmissionAndCloseDurabilityFailuresRetainEvidence`: admission receipt
  file/directory, close media/directory and close receipt file/directory sync faults.
  A complete receipt that survived an unknown fsync acknowledgement can recover; a
  missing close receipt cannot. `testNarrationStopCannotRebindChangedAdmissionReceipt`
  checks the in-memory admission digest at native stop.
- Existing `CaptureJournalProcessKillTests` now also SIGKILLs child test processes before
  metadata, after admission, during recording, after stop, after seal and after ingest WAL.
  Incomplete cases retain original synthetic bytes; closed cases recover exactly once.
  Existing lifecycle/media kill cases remain unchanged and passing.
- Native `NarrationAdmissionTests` throws in the metadata hook and proves no recorder
  admission or destination deletion. It never constructs an AV recorder or accesses a mic.

Final verification commands (all exit 0):

```bash
uv run --script contract/validate_schemas.py
uv run --script contract/archive/validate_archives.py
uv run --script contract/live/validate_live_transport.py
uv run --script contract/live/validate_capture_coach_live.py
uv run --script contract/live/generate_capture_coach_fixtures.py --check
uv run --script contract/archive/container/generate_fixtures.py --check
cd macos && swift build && swift test
```

`LiveOtlpTests.testPostsSessionSpanAndCorrelatedLogs` skipped because
`JAZZ_LIVE_OTLP_ENDPOINT` was unset; no live endpoint was configured.
Intermediate build/targeted logs are retained in the same directory; no unresolved failure.

## Exact residuals and next gates

- Legacy claims without receipts, admission-only/empty files, crash audio without a
  durable verified stop, unexpectedly stopped/interrupted native recorders, unreadable
  containers, inconsistent clocks/metadata and changed files remain retained and blocked.
  The controller now surfaces the archive/error detail. There is no honest complete
  interval to export for these cases; no automated repair or guessed end time is supplied.
- Container probing only verifies native open/nonempty length after observed stop, not a
  full decode or hardware qualification. Real-Mac interruption/encoding/clock/long-capture
  tests remain required. This unit/process-kill evidence is not that qualification.
- Complete Start/Stop/Pause/recovery serialization, persisted Pause, bounded controller
  shutdown and physical OS fences remain M2b. Capacity/reserve enforcement remains M2c.
  Receipt/ledger recovery uses a recovery-only linear scan per receipt, not a new index;
  receipt retention/capacity and synchronous close hashing need resource qualification.
- Explicit archive-level confirmation and existing delivery policies are unchanged.
  No upload or synthetic confirmation is triggered by narration recovery.

## Parent acceptance

Fresh reviewer `4c984f95` passed the M2a slice with no blocking findings or repair rounds.
Review covered supplied phase.diff and affected source/test seams; runtime commands were
writer/parent-executed, not reviewer-executed. Full M1/M2/native qualification is not approved.

Parent inspected recorder admission/close callbacks, receipt validation and replay,
then reran every required contract check and `swift build && swift test`: **exit 0;
756 tests executed, one live-OTLP skip, zero failures**. Log:
`/tmp/jazz-continuous-eaa688eb/m2a/parent-validation.log`. `git diff --check` passed.

Workflow `92870b3f-f5a7-4c56-b491-2057387c1619` used 254,730 input + 56,706 output =
**311,436 reported tokens**. Added to prior 389,761: **701,197 / 800,000 used; 98,803 remain**.
Next: commit/push reviewed M2a, then M2b Stop/Pause intent and startup/recovery serialization;
physical privacy/resource and real-Mac gates remain explicit. No app deployment.
