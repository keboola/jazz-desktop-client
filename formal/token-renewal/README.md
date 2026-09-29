# Formal model: unattended device-token renewal (macOS)

A small TLA+ model of `DeviceTokenRenewer` and the Keychain credential slot, checked with TLC.
The server side (issuing, renewing and revoking device tokens in the processor Data App) is
modelled in `keboola/jazz`, `formal/enrollment/`.

## What is modelled

`tla/TokenRenewal.tla`, one Mac:

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
| TR_KeychainGenerationMonotone | KeychainGenerationMonotone | **violated**: StartAttempt (reads gen 1), Respond, ReEnroll (gen 2 written), Resume -> the slot holds gen 1 with the renewed token |
| TR_NoWriteAfterRevoke | NoWriteAfterRevoke | **violated**: StartAttempt, Respond, Disconnect (slot deleted, `stop()`), Resume -> the envelope and projections are written back |
| TR_ProjectionsConsistentWithVault | ProjectionsConsistentWithVault | violated only by a crash between `vault.replace` (:304) and `repairProjections` (:315); not a finding, see below |

## Findings

| ID | Finding | Severity | Test |
|---|---|---|---|
| D1 | A renewal that was in flight while the user imported a new enrollment commits `snapshot.renewed(with: grant)` over the new envelope (`DeviceTokenRenewer.swift:290, 304`; `JazzSignedDeviceCredentialVault.replace` has no generation check). The Keychain goes back to the older enrollment's bundle, generation and scope (for example the old Area) with a fresh token, and the newly imported credential is lost. The window is the whole network round trip. | MED | model trace only |
| D2 | `stop()` (`:114-136`) cancels the session, but an answer already delivered and waiting for the main actor still runs `commit`: after a disconnect the envelope, `kbcToken` and the routing are written back, so the Mac holds a working credential the user removed. The window is narrow (response delivered, continuation not yet run). `stop()` also leaves `attemptInFlight` set, and a cancelled attempt re-arms `retryTimer` through `handle()` after `stop()` (harmless: the next attempt finds no envelope). | MED | model trace only |

Not a finding: a crash between `vault.replace` (:304) and `repairProjections` (:315) leaves the
`kbcToken` projection and `archiveEnrollmentRouting` on the previous token. The model has no
relaunch, but the code repairs both on the next launch's reconnect
(`KeboolaConnection.swift:741-747`), and the signed envelope masks the projections on every
signed read path in between.

Why no replay: `DeviceTokenRenewer` is in the `JazzCapture` executable target and always writes
through the hard-coded `SignedDeviceCredentialKeychain.vault` (real Keychain), so D1/D2 cannot be
driven from a unit test without a Keychain harness. A fix would most likely re-read the slot at
commit time and compare it with the snapshot (same enrollment `bundleId`, same `tokenId`) before
replacing, and drop a result that arrives after `stop()`.

`macos/Tests/JazzCaptureCoreTests/FormalTokenRenewalTests.swift` holds two ordinary tests that
guard the model's assumptions in Core: `renewed(with:)` keeps the snapshot's enrollment generation,
and `vault.replace` is last-writer-wins, so replaying the D1 write sequence at vault level leaves
generation 1 in the slot. If either stops being true (for example the vault gains a
compare-and-swap), update the model.
