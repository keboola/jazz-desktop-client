# Formal model: whole-archive upload queue (ADR 0003)

A small TLA+ model of the desktop whole-archive upload queue, checked with TLC. It asks one
question: can the user's Cancel, a crash, the clock and the server interleave with the upload
coordinator so that the queue breaks a rule of
[ADR 0003](../../docs/adr/0003-confirmed-archive-delivery.md)? Every counterexample was checked
against the code. Each confirmed finding that could be replayed has an `XCTExpectFailure` test in
[`macos/Tests/JazzCaptureCoreTests/FormalArchiveUploadQueueTests.swift`](../../macos/Tests/JazzCaptureCoreTests/FormalArchiveUploadQueueTests.swift).

## What the model covers

`tla/ArchiveUploadQueue.tla` models ONE queued archive. Every operator names the Swift function
and lines it mirrors (`JazzCaptureCore/JazzArchiveUpload.swift`,
`JazzCapture/ArchiveUploadClient.swift`).

- **Queue record**: `state`, `resumeState`, whether `ingestId` and `uploadReceipt` are set, and
  `nextAttemptAt` as one bit (`wait`: the watermark is in the future). `isAllowed` is copied
  verbatim (`:1331-1379`). Each queue call (`beginIntent`, `setIntent`, `setUploadReceipt`,
  `markRetryable`, `markReconnectRequired`, `applyTerminal`, `retry`, `cancel`) is one atomic
  step, because it holds the queue lease and runs on the queue actor.
- **Coordinator** (`run`, `createIntent`, `finalize`, `poll`, `apply`, `handle`): a program
  counter with one step per queue call or network request. Every `await` between two steps is a
  point where other actors may act.
- **App scheduler** (`ArchiveUploadManager`): one pass at a time; `nudge()` is dropped while a
  pass runs; at the end of a pass a follow-up timer is armed only for `verifying`,
  `processing` and `retryable`.
- **Environment**: user Cancel and Retry, crash + relaunch, the clock passing a watermark, and a
  server that creates the ingest idempotently, accepts the PUT, finalizes, imports in the
  background, and may answer with a fault (network error, token rejected, `failed_retryable`) or
  end in `failed_terminal` / `rejected`.
- **Ghost variables** for the invariants: `cancelSeen` (the user cancelled and has not retried),
  `overwrote` (which queue operation moved a cancelled record), `finAfterCancel`, `opsSent`,
  `used` (edges taken, only in the coverage run).

**Abstracted away**: scope and route binding (always present), identity/digest conflicts and the
`conflict` state, queue-v1 records and legacy reconciliation, package tampering, exact timestamps,
`quarantined` (treated like `rejected`), and a second archive in the same pass.

`BytesRetained` and `SameOperationId` hold by construction in the model: no code path in
`JazzArchiveUpload.swift` deletes a queued package (the only `removeItem` is the staging file at
`:2552`), and a v2 record's `uploadOperationId` is only read. The model keeps them as invariants
so a future change to the model must preserve them.

## How to run

Java 17 and `tla2tools.jar` (`TLA2TOOLS` overrides the default path).

```sh
cd formal/archive-upload-queue/tla
java -XX:+UseParallelGC -cp ~/tools/tla/tla2tools.jar tlc2.TLC -workers auto -deadlock \
     -config ArchiveUploadQueue.cfg ArchiveUploadQueue.tla   # clean run: only what holds
./run_all.sh          # every property, one TLC run each (about 1.5 min)
./edge_coverage.sh    # which isAllowed edges any modelled path takes (about 1 min)
./trace.py out/<NAME>.json   # compact counterexample
```

Bounds (`run_one.sh` defaults): `MaxSteps = 4` adversarial events in total, at most 2 faults,
1 crash, 2 user clicks. `FIX=TRUE ./run_one.sh <INV>` checks the proposed fix (constant
`ApplyFix`: `cancelled` may only go to `queued`, the coordinator's own resume accepts only
`retryable`, and a pass end re-arms the follow-up for any runnable state).

## Results

| Property | Current code | With `ApplyFix` |
|---|---|---|
| `CancelSticky` (leave `cancelled` only by the user's Retry) | **violated**, 3 steps | holds (13,517 states; 61,908 at MaxSteps 6) |
| `CancelSticky_beginIntent` | **violated**, 3 steps | — |
| `CancelSticky_setIntent` | **violated**, 11 steps | — |
| `CancelSticky_setUploadReceipt` | **violated**, 9 steps | — |
| `CancelSticky_coordinatorRetry` | **violated**, 15 steps | — |
| `CancelSticky_applyTerminal` | **violated**, 16 steps | — |
| `CancelSticky_other` (`markRetryable`, `markReconnectRequired`) | holds (33,805 states) | — |
| `NoReadyAfterCancel` | **violated**, 17 steps | holds (13,517 states) |
| `NoFinalizeAfterCancel` (no finalize request after a cancel) | **violated**, 10 steps | **violated** (see C) |
| `NoStrandedRunnable` (no lost wake-up) | **violated**, 4 steps | holds (13,517 states) |
| `EventuallySettles` (liveness, weak fairness) | **violated** (lasso, 7 steps) | holds (17,309 states) |
| `SameOperationId` (ADR item 9) | holds (33,805; 247,484 at MaxSteps 6) | — |
| `BytesRetained` (ADR item 4) | holds (33,805; 247,484 at MaxSteps 6) | — |
| `T1_TerminalAbsorbing` (table) | **violated**: `cancelled` has 8 exits | — |
| `T1b_TerminalNotToConflict` (table) | **violated**: `ready` etc. may go to `conflict` | — |
| `T2_NoNonTerminalSink`, `T3_AutoRunNotTerminal`, `T4_AllReachable` (table) | hold | — |

Edge coverage (1,038,661 states): 57 of the 89 allowed `(from, to)` pairs are taken by some
modelled path. Of the 8 exits from `cancelled`, only `cancelled -> queued` is the user's Retry.
`cancelled -> creatingIntent | finalizing | verifying | processing | failedTerminal | rejected`
are taken ONLY by a coordinator step that raced with Cancel. (`-> quarantined` is not modelled.)
Most other untaken edges come from error paths the model does not generate (`handle` for a thrown
`.rejected` / `.quarantined`).

## Findings

| ID | Finding | Severity | Replay test |
|---|---|---|---|
| A1 | Cancel between `bindRoute` (`:2094`) and `beginIntent` (`:2188`): `isAllowed(cancelled, creatingIntent)` is true, the whole upload runs, the archive ends `ready`. | HIGH | `testA1CancelBeforeBeginIntentStaysCancelled` |
| A2 | Cancel while `createIntent` is in flight: the default branch `setIntent(.processing)` (`:2233`) overwrites `cancelled`; a `ready` reply then makes it `ready`. | HIGH | `testA2CancelDuringCreateIntentIsNotOverwrittenByTheResponse` |
| A3 | Cancel between the `state == .uploading` check (`:2222`) and `setUploadReceipt` (`:2225`): `cancelled -> finalizing`, then finalize is sent. | HIGH | `testA3CancelAfterUploadCheckIsNotFinalized` |
| A4 | The coordinator resumes a retryable finalize with the user-facing `queue.retry` (`:2105`), which accepts `cancelled` and returns it to `queued`; finalize is still sent and the record is left `queued` (the cancel is lost). | HIGH | `testA4CoordinatorResumeDoesNotUncancel` |
| A5 | Cancel while finalize or a status poll is in flight: `apply` -> `setIntent(.verifying / .processing)` overwrites `cancelled`; later polls reach `ready`. The widest window of the A family. | HIGH | `testA5CancelDuringFinalizeIsNotOverwrittenByTheResponse` |
| A6 | Same window, the server answers `failed_terminal` / `rejected`: `applyTerminal` overwrites `cancelled` and the user loses Retry. A `ready` answer is refused, so the table is not even consistent. | LOW | `testA6CancelDuringFinalizeIsNotReplacedByTerminalFailure` |
| T1 | `isTerminal` says `cancelled` is terminal, but `isAllowed` (`:1371-1375`) lets it go to 8 states. This is the root cause of A1-A6. Also every terminal state except `conflict` may go to `conflict`. | MED | `testT1CancelledIsTerminalInTheTransitionTable` |
| B | Lost wake-up: a Retry (or an enqueue) while a pass is running calls `nudge()`, which is dropped (`passTask != nil`, `:583-588`); the pass end arms a follow-up only for `verifying/processing/retryable` (`:665-671`, `nextAutomaticFollowUp :1987`). A `queued` record then waits until relaunch; a second Retry click throws (`queued` is not retryable). | MED | model only (app target, `@MainActor`, Keychain + real HTTP client) |
| C | `finalize(_:)` and `poll(_:)` never re-read the record. A cancel recorded after `setUploadReceipt` (e.g. while the credential is read) still sends finalize. The record stays `cancelled` only because `applyTerminal` refuses `cancelled -> ready`. Still violated with `ApplyFix`: fixing it needs a state check right before each request. | LOW | `testCNoFinalizeRequestAfterCancelIsRecorded` |

Suggested fix (checked as `ApplyFix`): allow only `cancelled -> queued` in `isAllowed` (so
`setIntent`, `setUploadReceipt`, `beginIntent` and `applyTerminal` refuse a cancelled record and
`handle` returns it unchanged), resume a retryable stage in the coordinator with a call that
accepts only `retryable`, and let the end of a pass re-run (or arm a follow-up) when any record is
still runnable.

### About the replay tests

The tests drive the real `JazzArchiveUploadQueue` and `JazzArchiveUploadCoordinator` with fakes
(control plane, transport, credentials). Cancel is injected either inside a fake network call
(A2, A5, A6, C) or inside the coordinator's `now()` clock, which is evaluated as the argument of
the next queue call (A1, A3, A4). The clock waits (at most 10 s) for a detached task that runs
the real `queue.cancel`. A1 and A4 count `now()` calls (`#3` = the `beginIntent` / `retry`
argument), so they depend on the current call order in `run`; each test asserts that the hook
fired. The tests were written without a Swift toolchain and have not been compiled here.

## Future work

A Lean statement of the transition-table facts (T1, T2, T4) would be trivial (`decide` over a
14x14 table) but was not written: no Lean toolchain here.
