# Formal models

Small TLA+ models of the macOS client's delivery protocols, checked with TLC. Every operator
names the Swift function and `file:line` it mirrors. Each confirmed counterexample that can be
driven without the Keychain or a live network is replayed against the real code in
`macos/Tests/JazzCaptureCoreTests/Formal*Tests.swift`; a reproduced bug sits inside
`XCTExpectFailure`, so the test turns red once a fix lands and the wrapper is removed.

The models are documentation and a bug-finding tool, not a CI gate. The approach follows
keboola/cli#793. Server-side models (archive ingest, enrollment saga, Storage Files, BDM turns,
discovery jobs) live in `keboola/jazz/formal/`.

| Topic | What is modelled | Findings |
|---|---|---|
| [`archive-upload-queue`](archive-upload-queue/README.md) | whole-archive queue (ADR 0003): `isAllowed`, coordinator steps, user Cancel/Retry, crash/relaunch, server faults | A1–A5: a Cancel is overwritten by a racing coordinator step and the cancelled archive is finalized, even `ready` (HIGH); A6: terminal answer removes Retry; T1: `isTerminal` and `isAllowed` disagree on `cancelled`; B: Retry during a pass is lost until relaunch; C: finalize sent after a recorded cancel. `uploadOperationId` stability and byte retention hold |
| [`artifact-delivery`](artifact-delivery/README.md) | Files projection of narration/screenshots: dedup, prepare/PUT, receipt, pending queue, crashes, list/HEAD faults | F1: crash between receipt and pending removal leaves a hot loop that re-fires `onDelivered` (HIGH); F2: one item can block the queue forever; F3: duplicate complete files after a failed list; F4: a lost PUT response deletes a complete file; F5: `onDelivered` can be skipped. The `NarrationDedup.decide` safety lemma holds |
| [`token-renewal`](token-renewal/README.md) | `DeviceTokenRenewer` vs re-enrollment and disconnect | D1: an in-flight renewal overwrites a newer enrollment (no CAS on the vault); D2: a renewal delivered as `stop()` runs writes the credential back. Model trace only: the renewer writes through the real Keychain |

## Running

Java 17+ and `tla2tools.jar` (https://github.com/tlaplus/tlaplus/releases). Each topic's `tla/`
has a clean `.cfg` (only invariants that hold) and `run_one.sh` / `run_all.sh` (output in the
ignored `out/`); `TLA2TOOLS` overrides the jar path (default `~/tools/tla/tla2tools.jar`).
