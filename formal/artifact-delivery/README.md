# formal/artifact-delivery

A TLA+ model of how the macOS client projects canonical archive artifacts (narration audio,
screenshots) to Keboola Storage Files, checked with TLC. Each confirmed counterexample is
replayed against the real Swift code in
`macos/Tests/JazzCaptureCoreTests/FormalArtifactDeliveryTests.swift`.

## What is modelled

Paths are relative to `macos/Sources`.

| Model action | Real code |
|---|---|
| `StartPass` | `ArchiveArtifactUploader.drainOnce` 100-106, `JazzArchiveDeliveryQueue.pending` 120-131 (sorted by `queuedAt`, then `artifactId`) |
| `List` | `existingRemoteId` 163-180: `KeboolaClient.listFiles` 228-245 (returns `[]` on any error), HEAD `gcsObjectExists` 252-264 (true / false / nil), `NarrationDedup.decide` 42-56, `deleteFile` for each dangling id |
| `PrepOk` / `PrepFail` | `drainOnce` 126-133 (`prepareFile`) |
| `PutOk` / `PutFail` / `PutLostResponse` | `drainOnce` 142-156 (PUT; on any error `try? deleteFile(prepared.id)`) |
| `MD1` / `MD2` | `markDelivered` 133-177: when a receipt exists (143-157) it must name the same id (147-148), then the pending entry is removed if still there (153-155, the F1 fix); otherwise receipt `writeOnce` (167), `removeItem(pending)` (175) |
| `Notify` | `finish` 186 (`onDelivered`, which drives `onSegmentReady` in `CaptureController.swift` 414-424) |
| `Crash` | process death between any two steps; the relaunch starts a new pass from disk |

Environment: two artifacts (`a1` sorted before `a2`), three Storage file ids, up to two crashes,
`StepBound` = 24 steps. Faults that can be switched on and off: list error, list lag (a listing
misses recent files), HEAD answers nil, PUT lands but its response is lost, PUT fails,
prepare fails.

Abstracted away: bytes and digests, the archive-read failure path (a deliberate wait for
archive recovery), backoff timing, status publishing, the `created` timestamp (file ids are
minted in creation order, so "oldest first" means "lowest id"). There is one uploader, so the
model has no concurrent writers.

## Invariants

- `NoDuplicateComplete`: at most one complete Storage file per artifact.
- `OnDeliveredOnce`: `onDelivered` fires at most once per artifact.
- `NoLiveObjectDeleted`: a Storage record that holds real bytes is never deleted.
- `PendingClearedAfterReceipt`: after a pass that `drainOnce` reports as complete, no item that
  has a receipt is still pending.
- `QueueProgress`: between passes, every pending item that has a receipt can be finished on a
  perfect network, because dedup picks exactly the receipted file. This is a safety
  approximation of "one item never blocks the queue forever".
- `ReceiptPointsToComplete`: a receipt always names a complete file of the same artifact.
- `DedupLemma`: the safety lemma of the pure `NarrationDedup.decide`. The reused id and the
  deleted ids never overlap, only records whose HEAD returned 404 are deleted, and the reused
  id had HEAD 200.

## How to run

```sh
cd formal/artifact-delivery/tla
./run_all.sh                           # one TLC run per invariant, logs in out/ (~40 s)
./run_one.sh QueueProgress 24          # a single invariant
java -cp /path/to/tla2tools.jar tlc2.TLC -deadlock -config ArtifactDelivery.cfg ArtifactDelivery.tla
```

`ArtifactDelivery.cfg` is the clean run: all faults on, and only the invariants that hold.
`-deadlock` is needed because the system rightly stops once the queue is empty.
`run_one.sh` arguments: `INV [MaxSteps] [ListFail] [ListLag] [HeadUnk] [LostResp] [PutFail]
[PrepFail] [MaxCrashes]`.

## Results (TLC 2026.09.25, StepBound 24)

| Invariant | Environment | Result |
|---|---|---|
| TypeOK, DedupLemma, ReceiptPointsToComplete | all faults | holds, 61,814 distinct states |
| NoDuplicateComplete | all faults | **violated** (12-state trace) |
| NoDuplicateComplete | perfect list + HEAD | holds, 11,621 |
| OnDeliveredOnce | all faults | holds, 61,814 (violated in ~16 states before the F1 fix) |
| NoLiveObjectDeleted | all faults | **violated** (5 states) |
| NoLiveObjectDeleted | no lost PUT response | holds, 20,379 |
| PendingClearedAfterReceipt | all faults | holds, 61,814 (violated in ~19 states before the F1 fix) |
| QueueProgress | all faults | **violated** (11 states) |
| QueueProgress | no lost PUT response | **violated** (12 states) |
| QueueProgress | perfect list + HEAD / no crashes | holds, 11,621 / 4,723 |

With several workers TLC does not always report the shortest trace, so the lengths marked ~
can vary between runs.

### Traces

- **NoDuplicateComplete.** Pass 1: prepare, PUT succeeds, crash before `markDelivered`. Pass 2:
  `listFiles` fails and returns `[]` (or lags, or HEAD returns nil), so the client prepares
  and PUTs again. The artifact now has two complete Storage files.
- **OnDeliveredOnce / PendingClearedAfterReceipt** (before the F1 fix). Pass 1: upload, the
  receipt is written, crash before `removeItem(pending)`. Pass 2: dedup reuses the same file,
  `markDelivered` finds the receipt and returned it without removing the pending entry,
  `onDelivered` fired, and `drainOnce` returned true while the item was still pending, so
  every later pass fired `onDelivered` again. With the fix, pass 2 removes the pending entry
  and `onDelivered` fires exactly once (pass 1 crashed before reaching it).
- **NoLiveObjectDeleted.** The PUT lands in GCS, but the response is lost (a timeout after the
  upload finished). The catch at 153-154 deletes `prepared.id`, a record that holds the bytes.
- **QueueProgress.** Pass 1: the PUT response is lost and the cleanup DELETE also fails
  (without lost responses: a crash after the PUT), which leaves an orphan complete file, id 1.
  Pass 2: the listing returns `[]`, the client uploads id 2 and writes a receipt for it, then
  crashes before removing the pending entry. From then on every pass lists [1, 2], and dedup
  reuses the oldest, id 1. `markDelivered(1)` conflicts with the receipt's id 2 (147-148), so
  `finish` and `drainOnce` return false, and `a2` is never attempted again.

## Findings

| ID | Finding | Severity | Replay |
|---|---|---|---|
| F1 | **Fixed.** `markDelivered` returned early when a receipt existed and left the pending entry. A crash between the receipt `writeOnce` and `removeItem(pending)` left the item pending for good. On every pass `drainOnce` then re-listed and HEADed the file, called `onDelivered` again (a duplicate `onSegmentReady` / live BDM segment push, duplicate screenshot ids in `labelScreenshots`), and returned true. `run()` then saw a non-empty queue and looped without waiting (`ArchiveArtifactUploader.swift` 74-76), a hot network loop that survived relaunch. Fix: when the existing receipt names the same file id, `markDelivered` now removes the pending entry if it is still there (`JazzArchiveDeliveryQueue.swift` 153-155) before returning the receipt; `onDelivered` then fires once, on the recovering pass (the crashed pass never reached it). OnDeliveredOnce and PendingClearedAfterReceipt now hold with all faults on. | HIGH | `testF1RetryAfterCrashBetweenReceiptAndPendingRemovalClearsPending` (a passing guard) |
| F2 | A receipted pending item whose receipt names a newer duplicate conflicts on every pass. Dedup reuses the oldest complete copy (`NarrationDedup.swift` 48), `markDelivered` throws `.conflict` (147-148), and `drainOnce` returns false (110). The item sorts first, so every item queued after it is blocked forever. It needs an orphan complete copy (F3/F4), a failed or lagging list, and the crash window between the receipt write and the pending removal (still possible after the F1 fix, which only recovers a retry that finds the receipted id). Open. | MED | `testF2ReceiptedItemWithOlderDuplicateCanStillBeFinished` (XCTExpectFailure). The replay is at queue level (dedup decision plus `markDelivered`); a fix in the uploader, such as consulting `queue.receipt` before dedup, would need the test updated. |
| F3 | Duplicate complete Storage files. `listFiles` returns `[]` on error (`KeboolaClient.swift` 238-241), which looks the same as "nothing uploaded". A lagging listing or a nil HEAD also causes a second prepare and PUT after a crash between the PUT and the receipt. | MED | model only (the `KeboolaClient` sessions are `private static`, and the uploader has no seam for injecting them) |
| F4 | When the PUT response is lost after the object landed, the cleanup deletes a live record (`ArchiveArtifactUploader.swift` 153-154). The data is not lost, because the archive keeps the bytes and the retry re-uploads them. When that DELETE also fails, the orphan complete copy feeds F2 and F3. | LOW | model only |
| F5 | (Found by reading the code, not model-checked.) A crash between `markDelivered` returning and `onDelivered` (`finish` 184-186) means `onDelivered` never fires for that artifact, because pending is already cleared. The live segment push is lost, and only the post-hoc path recovers it. | LOW | none |

## Holds

`ReceiptPointsToComplete` holds: a receipt never names a deleted or dangling file, because dedup
deletes only 404 records, and the lost-response delete only ever hits a file that was never
receipted. `DedupLemma` holds in the model. `testDedupLemmaExhaustive` also checks it
exhaustively on the real `decide` for every candidate list of up to 3 entries over
{true, false, nil}; that test is expected to pass. A Lean proof of the lemma for all lists is
possible future work: `decide` is a simple fold, and the lemma follows by induction on the
list.
