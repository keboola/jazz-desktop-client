---------------------------- MODULE TokenRenewal ----------------------------
(***************************************************************************)
(* The macOS unattended device-token renewal against the Keychain slot,    *)
(* interleaved with a manual re-enrollment (bundle import), a disconnect   *)
(* (network authority revoked) and a process crash.                       *)
(*                                                                         *)
(* Source (macos/Sources/, at the time of writing):                        *)
(*   JazzCapture/DeviceTokenRenewer.swift                                  *)
(*       renew(trigger:)   145-279  (envelope read :150, attemptInFlight   *)
(*                                   :146/:260/:271, network await :266)   *)
(*       commit(_:replacing:at:) 283-339 (vault.replace :304, projections  *)
(*                                   :315-316, anchor :319-323)            *)
(*       handle(...) 341-380 (retry timer), stop() 114-136                 *)
(*   JazzCapture/DeviceTokenRenewalClient.swift invalidate() 116-118       *)
(*       (session.invalidateAndCancel)                                     *)
(*   JazzCapture/SignedDeviceCredentialKeychain.swift vault 30-33,         *)
(*       repairProjections 39-50                                           *)
(*   JazzCapture/Keychain.swift set = update-or-add (one item, atomic)     *)
(*   JazzCapture/KeboolaConnection.swift revokeNetworkAuthority 994-1006,  *)
(*       disconnect 758-778, signed import commit 600-613 (vault.replace   *)
(*       then projections), launch reconnect repair 741-747 (not modelled) *)
(*   JazzCapture/AppDelegate.swift onEndpointStored 133-143,               *)
(*       onNetworkAuthorityRevoked 145                                     *)
(*   JazzCaptureCore/DeviceTokenRenewal.swift renewed(with:) 340-373        *)
(*   JazzCaptureCore/SignedDeviceCredentialEnvelope.swift                  *)
(*       JazzSignedDeviceCredentialVault.replace 207-211 (no CAS)          *)
(*                                                                         *)
(* Everything on the main actor is one atomic step between awaits; the     *)
(* only await in an attempt is the network call. The server is abstract:   *)
(* a request either returns a grant (a fresh token) or fails. A grant      *)
(* whose continuation was already queued when stop() cancelled the session *)
(* is modelled by splitting "response arrives" from "main actor resumes".  *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    EnableReEnroll,   \* the user imports a new enrollment bundle
    EnableDisconnect, \* the user disconnects / authority is revoked
    EnableCrash,      \* the process dies at an arbitrary point
    MaxSteps

None == 0
NoEnv == [present |-> FALSE, gen |-> 0, tok |-> None]

VARIABLES
    vault,      \* Keychain signed-envelope slot: [present, gen, tok]
    kbcProj,    \* Keychain kbcToken projection (legacy read path)
    routeGen,   \* UserDefaults archiveEnrollmentRouting (its generation, 0 = nil)
    rpc,        \* renewer: "idle" | "inflight" | "responded"
    snap,       \* the envelope read at :150 for the attempt in flight
    grant,      \* token in the response, None = failed/cancelled
    cancelled,  \* stop() invalidated the session while the request was open
    maxGen,     \* ghost: newest generation the user ever imported
    nextTok,
    revoked,    \* ghost: the user disconnected and has not re-enrolled
    steps

vars == <<vault, kbcProj, routeGen, rpc, snap, grant, cancelled, maxGen, nextTok, revoked, steps>>

Init ==
    /\ vault = [present |-> TRUE, gen |-> 1, tok |-> 1]
    /\ kbcProj = 1
    /\ routeGen = 1
    /\ rpc = "idle"
    /\ snap = NoEnv
    /\ grant = None
    /\ cancelled = FALSE
    /\ maxGen = 1
    /\ nextTok = 2
    /\ revoked = FALSE
    /\ steps = 0

Step == steps' = steps + 1

\* renew(): guard !attemptInFlight (:146), read the envelope (:150), build
\* the request, set attemptInFlight (:260), await the network (:266).
StartAttempt ==
    /\ Step
    /\ rpc = "idle" /\ vault.present
    /\ snap' = vault
    /\ rpc' = "inflight"
    /\ cancelled' = FALSE
    /\ UNCHANGED <<vault, kbcProj, routeGen, grant, maxGen, nextTok, revoked>>

\* The HTTP exchange completes (URLSession delivered the body) or fails.
\* A session invalidated by stop() can only fail from now on.
Respond ==
    /\ Step
    /\ rpc = "inflight"
    /\ \/ /\ ~cancelled
          /\ grant' = nextTok /\ nextTok' = nextTok + 1
       \/ grant' = None /\ UNCHANGED nextTok
    /\ rpc' = "responded"
    /\ UNCHANGED <<vault, kbcProj, routeGen, snap, cancelled, maxGen, revoked>>

\* The main actor resumes after the await (:271-278). A grant is committed
\* with NO re-read of the vault: envelope.renewed(with:) of the SNAPSHOT
\* (:290) replaces the whole slot (:304). A failure goes through handle()
\* and re-arms the retry timer (:379).
Resume ==
    /\ Step
    /\ rpc = "responded"
    /\ IF grant # None
          THEN /\ vault' = [present |-> TRUE, gen |-> snap.gen, tok |-> grant]
               /\ rpc' = "committed"
          ELSE /\ vault' = vault
               /\ rpc' = "idle"
    /\ grant' = grant
    /\ UNCHANGED <<kbcProj, routeGen, snap, cancelled, maxGen, nextTok, revoked>>

\* Same synchronous main-actor run: repairProjections (:315) and the routing
\* in UserDefaults (:316). Only a process death can separate it from Resume.
Project ==
    /\ Step
    /\ rpc = "committed"
    /\ kbcProj' = grant
    /\ routeGen' = snap.gen
    /\ rpc' = "idle"
    /\ grant' = None
    /\ UNCHANGED <<vault, snap, cancelled, maxGen, nextTok, revoked>>

\* A bundle import (KeboolaConnection signed import commit 600-613): the new
\* envelope, its projections and routing are written, then onEndpointStored
\* calls start(kickOff:false) + renewIfDue(), which returns at the
\* attemptInFlight guard while an attempt is open.
ReEnroll ==
    /\ Step
    /\ EnableReEnroll /\ maxGen < 3 /\ rpc # "committed"
    /\ vault' = [present |-> TRUE, gen |-> maxGen + 1, tok |-> nextTok]
    /\ kbcProj' = nextTok
    /\ routeGen' = maxGen + 1
    /\ maxGen' = maxGen + 1
    /\ nextTok' = nextTok + 1
    /\ revoked' = FALSE
    /\ UNCHANGED <<rpc, snap, grant, cancelled>>

\* disconnect(): revokeNetworkAuthority deletes kbcToken, the stream
\* projection and the envelope, then onNetworkAuthorityRevoked -> stop()
\* (invalidateAndCancel; attemptInFlight is NOT cleared); disconnect then
\* clears the routing.
Disconnect ==
    /\ Step
    /\ EnableDisconnect /\ vault.present /\ rpc # "committed"
    /\ vault' = NoEnv
    /\ kbcProj' = None
    /\ routeGen' = 0
    /\ cancelled' = (rpc = "inflight")
    /\ revoked' = TRUE
    /\ UNCHANGED <<rpc, snap, grant, maxGen, nextTok>>

\* The process dies: the in-flight attempt is lost; the Keychain and
\* UserDefaults keep what was written.
Crash ==
    /\ Step
    /\ EnableCrash /\ rpc # "idle"
    /\ rpc' = "idle" /\ grant' = None /\ cancelled' = FALSE
    /\ UNCHANGED <<vault, kbcProj, routeGen, snap, maxGen, nextTok, revoked>>

Next == StartAttempt \/ Respond \/ Resume \/ Project \/ ReEnroll \/ Disconnect \/ Crash

Spec == Init /\ [][Next]_vars

StepBound == steps < MaxSteps

(* ---- invariants --------------------------------------------------------- *)

TypeOK ==
    /\ rpc \in {"idle", "inflight", "responded", "committed"}
    /\ vault.gen \in 0..maxGen
    /\ kbcProj \in 0..nextTok

\* The Keychain only moves forward by generation: a renewal of an older
\* enrollment never overwrites a newer imported one.
KeychainGenerationMonotone == vault.present => vault.gen = maxGen

\* After a disconnect nothing writes a credential back until the user
\* imports a new enrollment.
NoWriteAfterRevoke == revoked => (~vault.present /\ kbcProj = None /\ routeGen = 0)

\* The single-value projections agree with the atomic slot (checked outside
\* the synchronous commit, i.e. whenever the main actor is not mid-commit).
ProjectionsConsistentWithVault ==
    (rpc # "committed") =>
        (/\ kbcProj = (IF vault.present THEN vault.tok ELSE None)
         /\ routeGen = (IF vault.present THEN vault.gen ELSE 0))

\* Sanity: an attempt never commits a token it did not receive.
VaultTokenWasIssued == vault.present => vault.tok < nextTok
=============================================================================
