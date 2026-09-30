# Formal model: unattended device-token renewal (macOS)

A small TLA+ model of `DeviceTokenRenewer` and the Keychain credential slot, checked with TLC.
The server side (issuing, renewing and revoking device tokens in the processor Data App) is
modelled in `keboola/jazz`, `formal/enrollment/`.

## What is modelled

`tla/TokenRenewal.tla`, one Mac, as the code stood before the D1/D2 fix (line numbers refer to
that version; the model has no fix switch):

- **Renewer** (`JazzCapture/DeviceTokenRenewer.swift`): an attempt reads the signed envelope from
  the Keychain (`renew` :150), sets `attemptInFlight`, and awaits the network (:266). When the
  main actor resumes it builds `envelope.renewed(with: grant)` from the envelope it read (:290),
  replaces the whole Keychain slot (`vault.replace` :304, no re-read, no compare-and-swap), then
  writes the projections (`repairProjections` :315, routing in UserDefaults :316).
- **Re-enrollment**: a new signed bundle is imported (`KeboolaConnection`, new envelope +
  projections + routing); `onEndpointStored` then calls `start(kickOff: false)` and
  `renewIfDue()`, which returns at the `attemptInFlight` guard.
- **Disconnect**: `revokeNetworkAuthority` deletes `kbcToken`, the stream projection and the
  envelope, then `onNetworkAuthorityRevoked` -> `stop()`, which cancels the URL session
  (`invalidateAndCancel`) but not an answer whose continuation is already queued.
- **Crash**: the process dies at any point.

All main-actor code between two awaits is one atomic step. The only await in an attempt is the
network call, so "response delivered" and "main actor resumes" are separate steps; that split is
what lets a disconnect or a re-import run in between. The server is abstract: a request returns a
fresh token or fails.

**Abstracted away:** the schedule, backoff and jitter (`JazzDeviceTokenRenewalPolicy`), the
once-a-minute floor, the grant validation (`JazzDeviceTokenRenewalGrant`, tested in Core), the
stream endpoint, the renewal anchor in UserDefaults, token expiry.

## How to run

```sh
cd formal/token-renewal/tla
java -XX:+UseParallelGC -cp ~/tools/tla/tla2tools.jar tlc2.TLC -workers auto -deadlock \
     -config TokenRenewal.cfg TokenRenewal.tla   # clean run, holds
./run_all.sh                                     # one TLC run per invariant (seconds)
./trace.py out/<NAME>.log vault kbcProj rpc      # compact counterexample
```

`TLA2TOOLS` overrides the jar path. `MaxSteps = 14` (state constraint) bounds the depth.

## Results

| Run | Invariant | Result |
|---|---|---|
| TR_clean | VaultTokenWasIssued (all actors) | holds (7,478 states) |
| TR_renewal_only | KeychainGenerationMonotone, NoWriteAfterRevoke, ProjectionsConsistentWithVault (renewal alone, no crash) | holds (53 states) |
| TR_KeychainGenerationMonotone | KeychainGenerationMonotone | **violated** (pre-fix code, D1): StartAttempt (reads gen 1), Respond, ReEnroll (gen 2 written), Resume -> the slot holds gen 1 with the renewed token |
| TR_NoWriteAfterRevoke | NoWriteAfterRevoke | **violated** (pre-fix code, D2): StartAttempt, Respond, Disconnect (slot deleted, `stop()`), Resume -> the envelope and projections are written back |
| TR_ProjectionsConsistentWithVault | ProjectionsConsistentWithVault | violated only by a crash between `vault.replace` (:304) and `repairProjections` (:315); not a finding, see below |

## Findings

| ID | Finding | Severity | Status / guard test |
|---|---|---|---|
| D1 | A renewal that was in flight while the user imported a new enrollment commits `snapshot.renewed(with: grant)` over the new envelope (`DeviceTokenRenewer.swift:290, 304`; `JazzSignedDeviceCredentialVault.replace` has no generation check). The Keychain goes back to the older enrollment's bundle, generation and scope (for example the old Area) with a fresh token, and the newly imported credential is lost. The window is the whole network round trip. | MED | **fixed**: the renewer commits through `JazzSignedDeviceCredentialVault.commitRenewal`, a compare-and-set that re-reads the slot and writes only if it is still the snapshot (`isSameCredential`); otherwise the renewed token is dropped. A failed answer of a superseded attempt is dropped too (`renewalDecision`, no status, no backoff), and either way a fresh due check runs for the current credential. Guards: `FormalTokenRenewalTests.testD1_RenewalDoesNotOverwriteANewerEnrollment`, `testD1_RenewalDoesNotOverwriteAnotherRenewalOfTheSameEnrollment`, `testRenewalDecisionMarksAFailureOfASupersededAttemptStale` |
| D2 | `stop()` (`:114-136`) cancels the session, but an answer already delivered and waiting for the main actor still runs `commit`: after a disconnect the envelope, `kbcToken` and the routing are written back, so the Mac holds a working credential the user removed. The window is narrow (response delivered, continuation not yet run). `stop()` also leaves `attemptInFlight` set, and a cancelled attempt re-arms `retryTimer` through `handle()` after `stop()` (harmless: the next attempt finds no envelope). | MED | **fixed**: `stop()` bumps a lifecycle generation that the attempt captures before the await; a stopped attempt passes `renewerStopped` and writes nothing (and a failed one no longer re-arms `retryTimer`), and an emptied slot alone also refuses the write. If the renewer was started again meanwhile, a fresh due check runs; a renewer that stayed stopped is not re-armed. Guards: `FormalTokenRenewalTests.testD2_RenewalAfterDisconnectWritesNothingBack`, `testD2_RenewalAfterStopWritesNothing` |

Not a finding: a crash between `vault.replace` (:304) and `repairProjections` (:315) leaves the
`kbcToken` projection and `archiveEnrollmentRouting` on the previous token. The model has no
relaunch, but the code repairs both on the next launch's reconnect
(`KeboolaConnection.swift:741-747`), and the signed envelope masks the projections on every
signed read path in between.

How the fix is tested: `DeviceTokenRenewer` is in the `JazzCapture` executable target and writes
through the real Keychain, so the decision lives in Core (`JazzDeviceTokenRenewalCommitDecision`,
`JazzSignedDeviceCredentialVault.commitRenewal`) and the guards replay the D1/D2 traces against it
over an in-memory slot. The re-read and the write are not one Keychain operation; they are atomic
against every other writer (enrollment import, disconnect) because all of them run on the main
actor and `commitRenewal` has no suspension point. A dropped renewed token is not revoked (the
client has no revoke call for a device token); it stays valid server-side until its own expiry,
held by nobody.

`macos/Tests/JazzCaptureCoreTests/FormalTokenRenewalTests.swift` also keeps the two tests of the
model's pre-fix assumptions: `renewed(with:)` keeps the snapshot's enrollment generation, and a
plain `vault.replace` is still last-writer-wins, which is why a renewal must not use it.
