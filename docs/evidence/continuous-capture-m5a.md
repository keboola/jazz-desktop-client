# M5a — review-required time/size segmentation

Baseline `a7f0854`, `feat/company-recording-policy`. **Scoped code accepted after repair 1/3**;
fresh repair reviewer `055eb816` passed and parent verification passed. ADR 0005 remains **PROPOSED**. No contract, source authority,
confirmation, finalizer, delivery queue, idle monitor or installed-app changes.

## Behavior and measurement

- Original successful Start arms recording in memory. Ordinary chunks may roll under the same
  acknowledged setup/scope and live OS environment; neither manual nor continuous rotation calls
  public explicit Start. Stop/Pause/privacy/fault/exit disarm. Relaunch/reconnect cannot reconstruct
  manual intent; conservative interactive launch/wake eligibility is unchanged.
- One synchronous 1-second native timer samples a Foundation decision, without task fanout, tree
  scans or hashes. Duration uses system uptime; canonical evidence still uses UTC. A delayed sample
  produces at most one boundary, and each replacement starts a new deadline, not catch-up chunks.
- Initial engineering defaults: **1,800 seconds / 262,144,000 bytes (250 MiB)**. Decimal-string
  preferences `chunkDurationSeconds.v1` (60–1,800 seconds) and `chunkTargetBytes.v1`
  (33,554,432–262,144,000 bytes) permit lower tuning. Missing uses defaults; malformed, wrong-type,
  nonfinite or out-of-range values block. No new settings UI or capability API.
- The byte target is a conservative **cumulative write/media budget**, NOT current directory size:
  3× serialized WAL/checkpoint bytes (intent, materialization/package allowance); produced provisional
  screenshots before their next await (including superseded frames); native closed originals charged
  2× synchronously before seal/finalization; runtime known media charged before journal awaits; and
  journal artifact-copy bytes before ingestion. Active AAC size is freshly statted and counted 2×.
  Charges are not refunded after dedup, deletion of redundant WAL, copy completion or failed ingest.
  This deliberately rotates early compared with actual payload size.
- Add **16 MiB close/headroom allowance** to measured + pending bytes before comparing `>= target`.
  Resource checks retain M2c's fresh actual-volume reserve probes and also require known pending audio
  plus close allowance on the timer and close allowance during preparation. Unknown/negative/overflow
  accounting stops and requires explicit restart; it never discards a producer outcome or a claim.
  Unknown-size native frames still in flight cannot enter after source fencing. Already-returned
  frames are charged before further asynchronous enrichment. Native AAC buffering, admitted metadata,
  filesystem races and timer/run-loop delay can nevertheless overshoot the target; **this is not a
  hard exact cap**. Existing failed-close/ENOSPC retention remains authoritative.
- Available local portable importer/finalizer limits (`JazzArchiveImportLimits`) include 2 GiB ZIP,
  512 MiB entry, 256 MiB total structured data, 32 MiB JSON entry and 10,000 entries. The engineering
  target stays below the byte ceilings but does not prove every entry/count constraint. There is no
  advertised deployed receiver/proxy limit in the current protocol: **not negotiated server-limit
  proof**. Existing finalizer/import checks remain separate and may hold an oversized archive locally.
- `CaptureStartIntent.requestRotation/runRotation` coalesce duration/byte triggers, invalidate old
  callback generations, and reuse controller `stopCapture`, `CaptureLocalClose` and the normal
  `runStart` tail. Local commit **and actual physical quiescence** precede new IDs. Setup/notice,
  scope/authority, resources and OS eligibility are checked across awaits; Pause/Stop is actionable
  while closing or starting. Failed/late close cannot authorize replacement.
- Any open label, narration, retained label close or BDM workshop at a limit stops and disarms,
  revoking live environment acknowledgment so even continuous reconnect cannot restart. The menu
  requires explicit Start/Resume. No microphone restart, cross-label relation or workshop resumption
  is invented. This is intentional first-slice behavior, not completion of proposed continuation.
- Completed chunks remain local **Needs review**. Fresh archive/capture/stream/event IDs use the
  existing factory, unchanged scope and truthful timestamps; adjacent chunks never use
  `supersedesArchiveId`. Menu shows boundary reason and measured source-close/replacement-start gap,
  not a gapless claim. Existing explicitly enabled compatibility projections are unchanged.

## Initial checks and evidence

Logs: `/tmp/jazz-continuous-eaa688eb/m5a/`. Tests use temporary roots and production owners with fake
sources/permissions/authority/capacity, not native controller initialization or user recordings.

| Command | Result / log |
| --- | --- |
| `uv run --script contract/validate_schemas.py` | exit 0; `schemas.log` |
| `uv run --script contract/archive/validate_archives.py` | exit 0; `archives.log` |
| `uv run --script contract/live/validate_live_transport.py` | exit 0; `live-transport.log` |
| `uv run --script contract/live/validate_capture_coach_live.py` | exit 0; `capture-coach-live.log` |
| `uv run --script contract/live/generate_capture_coach_fixtures.py --check` | exit 0; `coach-fixtures.log` |
| `uv run --script contract/archive/container/generate_fixtures.py --check` | exit 0; `container-fixtures.log` |
| `cd macos && swift build` | exit 0; `build.log` |
| `cd macos && swift test` | exit 0; 845 tests, one expected live skip, zero failures; `test.log` |
| `cd macos && swift test --filter 'CaptureChunk\|CaptureStartIntentTests\|CapturePhysicalBoundaryTests\|CaptureLocalCloseTests\|CaptureLabelCloseTests\|CaptureResourceAdmissionTests\|CaptureSetupTests'` | exit 0; 65 tests; `focused.log` |

13 new tests in `CaptureChunkBoundaryTests` and `CaptureChunkRotationTests`: monotonic/wall separation,
exact equality/invalid bounds/unknown arithmetic, pending/native/media-copy charges, concurrent triggers,
deferred local commit plus delayed physical return, fresh IDs and no ZIP, manual arming, pre-task Stop,
Stop during preparation/after return, privacy/mode/exit, post-await notice/scope/authority/managed/resource
loss, failed/timed-out retained close, and labeled/narrated/workshop disarming. Full suite retains canonical,
confirmation and exact-ZIP retry coverage. An initial new test used an invalid screenshot fixture without
required evidence metadata; changed the synthetic byte-accounting fixture to narration, then reran.
`focused-fixture-failure.log` preserves that test-development failure; it was not a production regression.

`phase.diff` includes new files against the baseline; `changed-files.txt`, `phase-stat.txt`,
`validation-exits.txt` and `writer.md` support shell-less review. No staged files, commits, push or deploy.

## Repair 1/3 — workshop owner stops with capture

Review-0 P1 accepted: capture stopped at its hard limit while the workshop panel/adaptive loop
remained active. `CaptureController.onWorkshopBoundaryStop` now synchronously calls the exact
`BdmWorkshopController.captureStoppedAtBoundary` method wired by AppDelegate before the existing
environment-owned capture close. It cancels pending startup, marks inactive, clears adaptive wait,
cancels fallback and hides the panel, then refreshes the menu. It never invokes `onStopCapture` or
`onEndSegment`: this is not user Pause or a second capture close. Explicit Finish retains its Stop.
A cancelled startup still owns its slot until actual return; late success cannot reopen the panel.

Three tests in `BdmWorkshopStartupTests` drive that wired method-reference callback on the real
workshop owner with injected panel visibility/fallback scheduling, plus actual `CaptureLocalClose`.
They cover running/adaptive-waiting state, late question/done/fallback, pending/scheduled startup,
a stop during `onStarted`, no duplicate capture/segment close, menu refresh and later explicit restart.
The targeted before-fix run exposed an already-enqueued old fallback advancing a restarted workshop;
`adaptiveRequest` now fences that callback. `repair-1-regression-before.log` records the one failure
(5 tests); this was after adding the owner callback/native test seams but before the timer fence,
not an untouched-baseline reproduction of P1. Pre-repair sources/patch are in `pre-repair-1/`.

Final repair verification (all exit 0): the same six validator commands above (`repair-1-*.log`),
`cd macos && swift build` (`repair-1-build.log`), and `cd macos && swift test`
(`repair-1-test.log`: **848 tests, one expected skip, zero failures**). Targeted command:
`cd macos && swift test --filter 'BdmWorkshopStartupTests|CaptureChunk|CaptureStartIntentTests|CapturePhysicalBoundaryTests|CaptureLocalCloseTests|CaptureLabelCloseTests|CaptureResourceAdmissionTests|CaptureSetupTests'`
passes **70 tests** (`repair-1-focused.log`). No native window/timer/recording, credentials or user
state was used by the new tests. Reviewed intent/byte/physical/confirmation behavior is unchanged.
`repair-delta.diff` isolates this repair; refreshed `phase.diff` includes all new files against
`a7f0854`, with refreshed inventories/statistics. No staging, commit, push or deployment.

## Parent acceptance and accounting

Reviewer `055eb816-ffd7-4af7-a2b8-34f9ce1e6a06` returned **PASS** for the scoped workshop repair.
Parent inspected the owner callback/cleanup and rotation boundary, then reran all six required
contract checks plus Swift build/test: **848 tests, one expected live skip, zero failures**.
`git diff --check` passed. Log: `parent-repair-validation.log`; review: `repair-review-1.md`.
This accepts reviewed code, not full M5, native qualification or deployment.

Initial workflow `995e36d2-d1e6-4f69-9311-1a60dace20b7`: 210,873 input + 42,090 output =
**252,963** child tokens. Repair/review workflow `697eac98-3b4b-4738-9d9c-d7ee5776be33`:
195,790 + 18,988 = **214,778**. Including prior 2,363,685, cumulative usage is
**2,831,426 / 3,200,000; 368,574 remain** before further work. Cache reads are excluded;
all previously recovered detached debits remain included.

## Remaining gates

Real-Mac lock/sleep/TCC/native stop and menu-run-loop latency;
CPU/bytes-per-hour, cumulative-counter conservatism, in-flight overshoot, receiver sizing and
sustained/overnight qualification. M5b idle/activity, narration/workshop continuation, unattended OS
authority and full M5 remain open. Defaults and close allowance are engineering choices, not measured
operating guarantees. No network capabilities or automatic company authorization were added.
