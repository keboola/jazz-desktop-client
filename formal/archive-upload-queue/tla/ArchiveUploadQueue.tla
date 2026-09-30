------------------------- MODULE ArchiveUploadQueue -------------------------
(***************************************************************************)
(* Finite model of the desktop whole-archive upload queue (ADR 0003,       *)
(* docs/adr/0003-confirmed-archive-delivery.md) for ONE queued archive.    *)
(*                                                                         *)
(* Mirrored code (file:line at the time of writing):                       *)
(*   macos/Sources/JazzCaptureCore/JazzArchiveUpload.swift                 *)
(*     isTerminal 373-378, canRunAutomatically 380-389                     *)
(*     JazzArchiveUploadQueue.retry 1021-1085, cancel 1087-1101,           *)
(*       beginIntent 1114-1136, setIntent 1138-1166,                       *)
(*       setUploadReceipt 1168-1188, markRetryable 1190-1216,              *)
(*       markReconnectRequired 1218-1241, applyTerminal 1243-1276,         *)
(*       isAllowed 1331-1379, resumableTarget 1381-1388                    *)
(*     JazzArchiveUploadCoordinator.run 2080-2127, createIntent 2177-2240, *)
(*       finalize 2242-2257, poll 2259-2268, apply 2270-2323,              *)
(*       handle 2325-2374, localState 2450, resumeState 2463,              *)
(*       markOrdinaryRetryable 2473-2499                                   *)
(*   macos/Sources/JazzCapture/ArchiveUploadClient.swift                   *)
(*     ArchiveUploadManager.retry 504-519, cancel 549-559, nudge 583-588,  *)
(*       recoverConfirmedAndDrain 600-613, runPass 615-648,                *)
(*       scheduleFollowUp 650-663, scheduleFollowUpIfNeeded 665-671        *)
(*                                                                         *)
(* Every queue call is one atomic step (it holds the queue lease and the   *)
(* queue actor); every `await` between two calls is a point where the user *)
(* (cancel / retry), a crash, time and the server may interleave.          *)
(* Abstracted away: scope/route binding (always present), identity/digest  *)
(* conflicts, queue-v1 records and legacy reconciliation, package          *)
(* tampering, exact timestamps (nextAttemptAt is one bit `wait`).          *)
(*                                                                         *)
(* Line numbers are those of the pre-fix code (commit ed71c47). The fix    *)
(* for A1-A6/T1 has since shipped; ApplyFix = TRUE models it, the default  *)
(* (FALSE) keeps the pre-fix code so the documented counterexamples stay   *)
(* reproducible. ApplyWakeFix models the still-proposed fix for B.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, TLC

CONSTANTS
    MaxSteps,         \* StepBound: total adversarial events (faults+crashes+user)
    MaxFaults,        \* network / credential / server-retryable faults
    MaxCrashes,       \* app crashes (process kill + relaunch)
    MaxUser,          \* user Cancel / Retry clicks
    EnableServerFail, \* server may end an ingest failed_terminal / rejected
    TrackEdges,       \* record every (from,to) state edge taken (coverage run)
    ApplyFix,         \* the shipped cancel-sticky fix (A1-A6, T1) instead of
                      \* the pre-fix code: cancelled -> queued only, and the
                      \* coordinator resumes with resumeRetryable, which
                      \* accepts only `retryable` (not the user's retry)
    ApplyWakeFix      \* the proposed fix for B (not in the code): a pass end
                      \* re-arms the follow-up for any runnable state

States == {"queued", "creatingIntent", "uploading", "finalizing", "verifying",
           "processing", "ready", "retryable", "reconnectRequired",
           "failedTerminal", "rejected", "quarantined", "conflict", "cancelled"}

\* JazzArchiveUploadState.isTerminal :373-378
Terminal == {"ready", "failedTerminal", "rejected", "quarantined", "conflict",
             "cancelled"}
\* JazzArchiveUploadState.canRunAutomatically :380-389
AutoRun == {"queued", "creatingIntent", "uploading", "finalizing", "verifying",
            "processing", "retryable"}

\* JazzArchiveUploadQueue.isAllowed :1331-1379 (verbatim)
CodeIsAllowed(from, to) ==
    IF from = to THEN from \in {"creatingIntent", "processing", "verifying"}
    ELSE IF to = "conflict" THEN from # "conflict"
    ELSE IF to = "cancelled" THEN from \notin Terminal
    ELSE CASE from = "queued" ->
                 to \in {"creatingIntent", "reconnectRequired", "retryable"}
           [] from = "creatingIntent" ->
                 to \in {"uploading", "verifying", "processing", "ready",
                         "retryable", "reconnectRequired", "failedTerminal",
                         "rejected", "quarantined"}
           [] from = "uploading" ->
                 to \in {"creatingIntent", "finalizing", "retryable",
                         "reconnectRequired", "failedTerminal", "rejected",
                         "quarantined"}
           [] from = "finalizing" ->
                 to \in {"verifying", "processing", "ready", "retryable",
                         "reconnectRequired", "failedTerminal", "rejected",
                         "quarantined"}
           [] from = "verifying" ->
                 to \in {"processing", "ready", "retryable", "reconnectRequired",
                         "failedTerminal", "rejected", "quarantined"}
           [] from = "processing" ->
                 to \in {"verifying", "ready", "retryable", "reconnectRequired",
                         "failedTerminal", "rejected", "quarantined"}
           [] from \in {"retryable", "reconnectRequired", "cancelled"} ->
                 to \in {"queued", "creatingIntent", "finalizing", "verifying",
                         "processing", "failedTerminal", "rejected",
                         "quarantined"}
           [] OTHER -> FALSE

IsAllowed(from, to) ==
    IF ApplyFix /\ from = "cancelled" /\ to # "conflict"
    THEN to = "queued"
    ELSE CodeIsAllowed(from, to)

Resumes == {"none", "queued", "creatingIntent", "finalizing", "verifying",
            "processing"}
SrvStates == {"none", "created", "uploaded", "processing", "ready", "failedT",
              "rejected"}
Resps == {"none", "created", "uploaded", "processing", "ready", "failedT",
          "rejected", "net", "token", "failedR"}
Pcs == {"idle", "start", "retry_fin", "retry_poll", "fin_send", "poll_send",
        "ci_begin", "ci_send", "ci_resp", "up_check1", "up_put", "up_check2",
        "up_receipt", "apply", "end"}
OverwriteOps == {"setIntent", "setUploadReceipt", "coordinatorRetry",
                 "applyTerminal", "markRetryable", "markReconnectRequired",
                 "beginIntent"}

VARIABLES
    st, resume, ingest, receipt, wait,  \* the durable queue record
    opId, bytes,                        \* uploadOperationId, retained package
    srv, putDone,                       \* server ingest + object-store PUT
    pc, resp,                           \* coordinator program counter / reply
    fu, app,                            \* follow-up timer armed, app up/down
    faults, crashes, user,              \* budgets
    cancelSeen,      \* ghost: user cancelled and has not retried since
    overwrote,       \* ghost: queue ops that moved a cancelled-by-user record
    finAfterCancel,  \* ghost: a finalize request left while cancelSeen
    opsSent,         \* ghost: operation ids put on the wire
    used             \* ghost: (from,to) edges taken (only if TrackEdges)

vars == <<st, resume, ingest, receipt, wait, opId, bytes, srv, putDone, pc,
          resp, fu, app, faults, crashes, user, cancelSeen, overwrote,
          finAfterCancel, opsSent, used>>

TypeOK ==
    /\ st \in States /\ resume \in Resumes
    /\ ingest \in BOOLEAN /\ receipt \in BOOLEAN /\ wait \in BOOLEAN
    /\ opId = "op1" /\ bytes \in BOOLEAN
    /\ srv \in SrvStates /\ putDone \in BOOLEAN
    /\ pc \in Pcs /\ resp \in Resps /\ fu \in BOOLEAN /\ app \in {"up", "down"}
    /\ cancelSeen \in BOOLEAN /\ overwrote \subseteq OverwriteOps
    /\ finAfterCancel \in BOOLEAN /\ opsSent \subseteq {"op1", "op2"}

Init ==
    /\ st = "queued" /\ resume = "none" /\ ingest = FALSE /\ receipt = FALSE
    /\ wait = FALSE /\ opId = "op1" /\ bytes = TRUE
    /\ srv = "none" /\ putDone = FALSE
    /\ pc = "start"          \* enqueueConfirmed -> nudge (ArchiveUploadClient :495-502)
    /\ resp = "none" /\ fu = FALSE /\ app = "up"
    /\ faults = 0 /\ crashes = 0 /\ user = 0
    /\ cancelSeen = FALSE /\ overwrote = {} /\ finAfterCancel = FALSE
    /\ opsSent = {} /\ used = {}

(* ---------------------------- helpers ---------------------------------- *)

Runnable == st \in AutoRun /\ ~(st = "retryable" /\ wait)   \* canRunAutomatically(at:) :543

Edge(to) == used' = IF TrackEdges THEN used \cup {<<st, to>>} ELSE used

\* Record which queue operation moved a record the user had cancelled.
Over(op, to) == overwrote' = IF st = "cancelled" /\ to # "cancelled"
                             THEN overwrote \cup {op} ELSE overwrote

\* resumableTarget :1381-1388
ResumableTarget ==
    CASE resume = "finalizing" /\ ingest /\ receipt -> "finalizing"
      [] resume = "verifying" /\ ingest -> "verifying"
      [] resume = "processing" /\ ingest -> "processing"
      [] OTHER -> "queued"

\* coordinator resumeState(for:) :2463-2471
ResumeFor ==
    CASE st = "finalizing" -> "finalizing"
      [] st = "verifying" -> "verifying"
      [] st = "processing" -> "processing"
      [] st \in {"retryable", "reconnectRequired"} ->
            IF resume = "none" THEN "queued" ELSE resume
      [] OTHER -> "creatingIntent"

RespOf(s) == CASE s = "created" -> "created" [] s = "uploaded" -> "uploaded"
               [] s = "processing" -> "processing" [] s = "ready" -> "ready"
               [] s = "failedT" -> "failedT" [] s = "rejected" -> "rejected"
               [] OTHER -> "none"

\* Faults the network / Keychain / server may return instead of a status.
FaultResps(s) == {"net", "token"} \cup
                 (IF s \in {"uploaded", "processing"} THEN {"failedR"} ELSE {})

Unchanged_env == UNCHANGED <<opId, bytes, app, crashes, user, cancelSeen>>

(* A queue write that may be refused by isAllowed. On refusal the code      *)
(* either returns the cancelled item (guards at :1204/:1228/:1253) or throws *)
(* invalidTransition which `handle` rethrows / returns (:2330): in all cases *)
(* the record is unchanged.                                                *)

\* setIntent :1138-1166 (same ingest id: the server is consistent here)
SetIntent(s, next) ==
    IF IsAllowed(st, s)
    THEN /\ st' = s /\ ingest' = TRUE /\ resume' = "none" /\ wait' = FALSE
         /\ Edge(s) /\ Over("setIntent", s) /\ pc' = next
    ELSE UNCHANGED <<st, ingest, resume, wait, used, overwrote>> /\ pc' = "end"

\* markRetryable :1190-1216 (nextAttemptAt is always set: server value or
\* the local backoff of markOrdinaryRetryable :2473-2499)
MarkRetryable(r) ==
    IF IsAllowed(st, "retryable")
    THEN /\ st' = "retryable" /\ resume' = r /\ wait' = TRUE
         /\ Edge("retryable") /\ Over("markRetryable", "retryable")
    ELSE UNCHANGED <<st, resume, wait, used, overwrote>>

\* markReconnectRequired :1218-1241
MarkReconnect(r) ==
    IF IsAllowed(st, "reconnectRequired")
    THEN /\ st' = "reconnectRequired" /\ resume' = r /\ wait' = FALSE
         /\ Edge("reconnectRequired") /\ Over("markReconnectRequired", "reconnectRequired")
    ELSE UNCHANGED <<st, resume, wait, used, overwrote>>

\* applyTerminal :1243-1276
ApplyTerminal(t) ==
    IF IsAllowed(st, t)
    THEN /\ st' = t /\ resume' = "none" /\ wait' = FALSE
         /\ Edge(t) /\ Over("applyTerminal", t)
    ELSE UNCHANGED <<st, resume, wait, used, overwrote>>

(* ------------------------ coordinator (one pass) ------------------------ *)

\* run :2080-2127 -- item read + canRunAutomatically + packageURL + bindRoute,
\* then dispatch on bound.state.
CStart ==
    /\ pc = "start"
    /\ pc' = IF ~Runnable THEN "end"
             ELSE CASE st = "finalizing" -> "fin_send"
                    [] st \in {"verifying", "processing"} -> "poll_send"
                    [] st = "retryable" /\ resume = "finalizing" /\ ingest /\ receipt
                        -> "retry_fin"
                    [] st = "retryable" /\ resume \in {"verifying", "processing"} /\ ingest
                        -> "retry_poll"
                    [] OTHER -> "ci_begin"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, srv, putDone, resp, fu,
                   faults, overwrote, finAfterCancel, opsSent, used>>
    /\ Unchanged_env

\* run :2104-2112 -- pre-fix, the coordinator itself calls queue.retry (:1021)
\* and then finalize/poll(requiredItem) WITHOUT looking at the returned state.
\* ApplyFix: queue.resumeRetryable, which accepts only `retryable`.
CRetry ==
    /\ pc \in {"retry_fin", "retry_poll"}
    /\ IF st \in (IF ApplyFix THEN {"retryable"}
                   ELSE {"retryable", "reconnectRequired", "cancelled"})
       THEN LET t == ResumableTarget IN
            /\ st' = t /\ resume' = "none" /\ wait' = FALSE
            /\ Edge(t) /\ Over("coordinatorRetry", t)
            /\ pc' = IF pc = "retry_fin" THEN "fin_send" ELSE "poll_send"
       ELSE /\ UNCHANGED <<st, resume, wait, used, overwrote>>   \* invalidTransition
            /\ pc' = "end"
    /\ UNCHANGED <<ingest, receipt, srv, putDone, resp, fu, faults,
                   finAfterCancel, opsSent>>
    /\ Unchanged_env

\* beginIntent :1114-1136 (createIntent :2188)
CBegin ==
    /\ pc = "ci_begin"
    /\ IF IsAllowed(st, "creatingIntent")
       THEN /\ st' = "creatingIntent" /\ resume' = "none" /\ wait' = FALSE
            /\ Edge("creatingIntent") /\ Over("beginIntent", "creatingIntent")
            /\ pc' = "ci_send"
       ELSE UNCHANGED <<st, resume, wait, used, overwrote>> /\ pc' = "end"
    /\ UNCHANGED <<ingest, receipt, srv, putDone, resp, fu, faults,
                   finAfterCancel, opsSent>>
    /\ Unchanged_env

\* controlPlane.createIntent :2189-2201 (credential read + request). The
\* server creates the ingest idempotently for the operation id.
CISend ==
    /\ pc = "ci_send"
    /\ opsSent' = opsSent \cup {opId}
    /\ \/ /\ srv' = IF srv = "none" THEN "created" ELSE srv
          /\ resp' = RespOf(srv') /\ faults' = faults
       \/ /\ faults < MaxFaults /\ faults' = faults + 1
          /\ \/ srv' = IF srv = "none" THEN "created" ELSE srv  \* lost reply
             \/ srv' = srv                                     \* never arrived
          /\ resp' \in FaultResps(srv')
    /\ pc' = "ci_resp"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, putDone, fu, overwrote,
                   finAfterCancel, used>>
    /\ Unchanged_env

\* createIntent :2202-2240
CIResp ==
    /\ pc = "ci_resp"
    /\ IF resp = "created"
       THEN SetIntent("uploading", "up_check1")                    \* :2208
       ELSE IF resp \in {"net", "token"}
       THEN UNCHANGED <<st, ingest, resume, wait, used, overwrote>> /\ pc' = "apply"
       ELSE LET local == CASE resp = "uploaded" -> "verifying"     \* localState :2450
                           [] resp = "processing" -> "processing"
                           [] resp = "ready" -> "ready"
                           [] resp = "failedT" -> "failedTerminal"
                           [] resp = "rejected" -> "rejected"
                           [] OTHER -> "retryable"
                persisted == IF local \in {"retryable", "failedTerminal", "rejected",
                                           "quarantined", "ready"}
                             THEN "processing" ELSE local            \* :2230-2232
            IN SetIntent(persisted, "apply")                        \* :2233
    /\ UNCHANGED <<receipt, srv, putDone, resp, fu, faults, finAfterCancel, opsSent>>
    /\ Unchanged_env

\* :2208 / :2222 -- `guard queue.item(...)?.state == .uploading`
CUpCheck ==
    /\ pc \in {"up_check1", "up_check2"}
    /\ pc' = IF st # "uploading" THEN "end"
             ELSE IF pc = "up_check1" THEN "up_put" ELSE "up_receipt"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, srv, putDone, resp, fu,
                   faults, overwrote, finAfterCancel, opsSent, used>>
    /\ Unchanged_env

\* packageURL + objectTransport.upload :2211-2221
CUpPut ==
    /\ pc = "up_put"
    /\ putDone' = TRUE
    /\ \/ /\ pc' = "up_check2" /\ faults' = faults /\ resp' = resp
       \/ /\ faults < MaxFaults /\ faults' = faults + 1
          /\ resp' = "net" /\ pc' = "apply"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, srv, fu, overwrote,
                   finAfterCancel, opsSent, used>>
    /\ Unchanged_env

\* setUploadReceipt :1168-1188, called at :2225 (then finalize(requiredItem))
CUpReceipt ==
    /\ pc = "up_receipt"
    /\ IF IsAllowed(st, "finalizing")
       THEN /\ st' = "finalizing" /\ receipt' = TRUE /\ resume' = "none"
            /\ wait' = FALSE /\ Edge("finalizing")
            /\ Over("setUploadReceipt", "finalizing") /\ pc' = "fin_send"
       ELSE UNCHANGED <<st, receipt, resume, wait, used, overwrote>> /\ pc' = "end"
    /\ UNCHANGED <<ingest, srv, putDone, resp, fu, faults, finAfterCancel, opsSent>>
    /\ Unchanged_env

\* controlPlane.finalize :2242-2257 -- no state check before the request.
CFinSend ==
    /\ pc = "fin_send"
    /\ ingest /\ receipt                    \* guard :2243-2247 (never cleared)
    /\ finAfterCancel' = (finAfterCancel \/ cancelSeen)
    /\ opsSent' = opsSent \cup {opId}
    /\ LET s2 == IF srv = "created" /\ putDone THEN "uploaded" ELSE srv IN
       \/ /\ srv' = s2 /\ resp' = RespOf(s2) /\ faults' = faults
       \/ /\ faults < MaxFaults /\ faults' = faults + 1
          /\ srv' \in {srv, s2} /\ resp' \in FaultResps(srv')
    /\ pc' = "apply"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, putDone, fu, overwrote, used>>
    /\ Unchanged_env

\* controlPlane.status :2259-2268
CPollSend ==
    /\ pc = "poll_send"
    /\ ingest
    /\ \/ /\ resp' = RespOf(srv) /\ faults' = faults
       \/ /\ faults < MaxFaults /\ faults' = faults + 1 /\ resp' \in FaultResps(srv)
    /\ pc' = "apply"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, srv, putDone, fu, overwrote,
                   finAfterCancel, opsSent, used>>
    /\ Unchanged_env

\* apply :2270-2323, handle :2325-2374, markOrdinaryRetryable :2473-2499.
\* A "net" error (URLError etc.) goes to markOrdinaryRetryable; "token"
\* (credentialExpired / tokenRejected) goes through handle, which first
\* returns a cancelled item unchanged (:2330).
CApply ==
    /\ pc = "apply"
    /\ CASE resp = "uploaded" -> SetIntent("verifying", "end")
         [] resp = "processing" -> SetIntent("processing", "end")
         [] OTHER -> /\ UNCHANGED ingest /\ pc' = "end"
                    /\ CASE resp = "net"      -> MarkRetryable(ResumeFor)
                         [] resp = "token"    -> MarkReconnect(ResumeFor)
                         [] resp = "failedR"  -> MarkRetryable("verifying")
                         [] resp = "created"  -> MarkRetryable("creatingIntent")
                         [] resp = "ready"    -> ApplyTerminal("ready")
                         [] resp = "failedT"  -> ApplyTerminal("failedTerminal")
                         [] resp = "rejected" -> ApplyTerminal("rejected")
    /\ UNCHANGED <<receipt, srv, putDone, resp, fu, faults, finAfterCancel, opsSent>>
    /\ Unchanged_env

\* runPass tail :640-647 -- refresh + scheduleFollowUpIfNeeded (only
\* verifying/processing/retryable arm a follow-up, nextAutomaticFollowUp :1987),
\* then passTask = nil.
CPassEnd ==
    /\ pc = "end"
    /\ pc' = "idle"
    /\ fu' = (fu \/ st \in (IF ApplyWakeFix THEN AutoRun
                            ELSE {"verifying", "processing", "retryable"}))
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, srv, putDone, resp,
                   faults, overwrote, finAfterCancel, opsSent, used>>
    /\ Unchanged_env

Coordinator == CStart \/ CRetry \/ CBegin \/ CISend \/ CIResp \/ CUpCheck
               \/ CUpPut \/ CUpReceipt \/ CFinSend \/ CPollSend \/ CApply
               \/ CPassEnd

(* ------------------------------ environment ---------------------------- *)

\* nudge :583-588 -- dropped while a pass is running (passTask != nil).
Nudged == IF pc = "idle" THEN "start" ELSE pc

\* follow-up timer :650-663 fires at the earliest deadline (for a retryable
\* item that is its nextAttemptAt, so the watermark has passed).
Timer ==
    /\ fu /\ app = "up"
    /\ fu' = FALSE /\ wait' = FALSE /\ pc' = Nudged
    /\ UNCHANGED <<st, resume, ingest, receipt, srv, putDone, resp, faults,
                   overwrote, finAfterCancel, opsSent, used>>
    /\ Unchanged_env

\* wall clock passes a nextAttemptAt watermark
Tick ==
    /\ wait /\ wait' = FALSE
    /\ UNCHANGED <<st, resume, ingest, receipt, opId, bytes, srv, putDone, pc,
                   resp, fu, app, faults, crashes, user, cancelSeen, overwrote,
                   finAfterCancel, opsSent, used>>

\* ArchiveUploadManager.cancel :549-559 -> queue.cancel :1087 (no nudge)
UCancel ==
    /\ app = "up" /\ user < MaxUser /\ user' = user + 1
    /\ IsAllowed(st, "cancelled")
    /\ st' = "cancelled" /\ resume' = "none" /\ wait' = FALSE
    /\ Edge("cancelled")
    /\ cancelSeen' = TRUE
    /\ UNCHANGED <<ingest, receipt, opId, bytes, srv, putDone, pc, resp, fu, app,
                   faults, crashes, overwrote, finAfterCancel, opsSent>>

\* ArchiveUploadManager.retry :504-519 -> queue.retry :1021-1085, then nudge
URetry ==
    /\ app = "up" /\ user < MaxUser /\ user' = user + 1
    /\ st \in {"retryable", "reconnectRequired", "cancelled"}
    /\ IF st = "retryable" /\ wait
       THEN UNCHANGED <<st, resume, wait, used, cancelSeen>>   \* watermark :1038-1045
       ELSE LET t == ResumableTarget IN
            /\ st' = t /\ resume' = "none" /\ wait' = FALSE /\ Edge(t)
            /\ cancelSeen' = IF st = "cancelled" THEN FALSE ELSE cancelSeen
    /\ pc' = Nudged
    /\ UNCHANGED <<ingest, receipt, opId, bytes, srv, putDone, resp, fu, app,
                   faults, crashes, overwrote, finAfterCancel, opsSent>>

\* process kill: the pass, its timer and the in-flight reply are lost
Crash ==
    /\ app = "up" /\ crashes < MaxCrashes /\ crashes' = crashes + 1
    /\ app' = "down" /\ pc' = "idle" /\ fu' = FALSE /\ resp' = "none"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, opId, bytes, srv, putDone,
                   faults, user, cancelSeen, overwrote, finAfterCancel, opsSent, used>>

\* relaunch: ArchiveUploadManager.init -> recoverConfirmedAndDrain -> nudge
Launch ==
    /\ app = "down" /\ app' = "up" /\ pc' = "start"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, opId, bytes, srv, putDone,
                   resp, fu, faults, crashes, user, cancelSeen, overwrote,
                   finAfterCancel, opsSent, used>>

\* server-side background import
ServerAdvance ==
    /\ srv \in {"uploaded", "processing"}
    /\ srv' = IF srv = "uploaded" THEN "processing" ELSE "ready"
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, opId, bytes, putDone, pc,
                   resp, fu, app, faults, crashes, user, cancelSeen, overwrote,
                   finAfterCancel, opsSent, used>>

ServerFail ==
    /\ EnableServerFail /\ faults < MaxFaults /\ faults' = faults + 1
    /\ srv \in {"uploaded", "processing"} /\ srv' \in {"failedT", "rejected"}
    /\ UNCHANGED <<st, resume, ingest, receipt, wait, opId, bytes, putDone, pc,
                   resp, fu, app, crashes, user, cancelSeen, overwrote,
                   finAfterCancel, opsSent, used>>

Next == Coordinator \/ Timer \/ Tick \/ UCancel \/ URetry \/ Crash \/ Launch
        \/ ServerAdvance \/ ServerFail

Fairness == WF_vars(Coordinator) /\ WF_vars(Timer) /\ WF_vars(Tick)
            /\ WF_vars(Launch) /\ WF_vars(ServerAdvance)

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ Fairness

StepBound == faults + crashes + user <= MaxSteps

(* ------------------------------ properties ------------------------------ *)

\* Out of `cancelled` only through the user's Retry.
CancelSticky == cancelSeen => st = "cancelled"
\* The same, one invariant per queue operation that can overwrite a cancel.
CancelSticky_beginIntent == "beginIntent" \notin overwrote
CancelSticky_setIntent == "setIntent" \notin overwrote
CancelSticky_setUploadReceipt == "setUploadReceipt" \notin overwrote
CancelSticky_coordinatorRetry == "coordinatorRetry" \notin overwrote
CancelSticky_applyTerminal == "applyTerminal" \notin overwrote
\* markRetryable / markReconnectRequired keep a cancel (guards :1204, :1228).
CancelSticky_other == overwrote \subseteq {"beginIntent", "setIntent", "setUploadReceipt",
                                            "coordinatorRetry", "applyTerminal"}
\* No finalize request is started after the user's cancel (until Retry).
NoFinalizeAfterCancel == ~finAfterCancel
\* A cancelled delivery is never shown as ready.
NoReadyAfterCancel == ~(cancelSeen /\ st = "ready")
\* ADR 0003 item 9: one operation id, never reminted.
SameOperationId == opsSent \subseteq {"op1"}
\* ADR 0003 item 4: local bytes kept on cancel and every failure.
BytesRetained == bytes
\* Lost wake-up: the app is up and idle, no follow-up is armed, yet the
\* record could run now. Nothing will ever run it until relaunch.
NoStrandedRunnable == ~(app = "up" /\ pc = "idle" /\ ~fu /\ Runnable)

\* Liveness (FairSpec): with a fair scheduler, the item settles.
Settled == {"ready", "cancelled", "failedTerminal", "rejected", "quarantined",
            "conflict", "reconnectRequired"}
EventuallySettles == <>[](st \in Settled)

(* -------------------- transition-table checks (constant) ----------------- *)

\* isTerminal and isAllowed agree: nothing leaves a terminal state
\* (conflict excepted, it is a separate question below) except the user's
\* explicit Retry of a cancelled record (cancelled -> queued). The table
\* checks use IsAllowed, i.e. the pre-fix table unless ApplyFix.
T1_TerminalAbsorbing ==
    \A s \in Terminal : \A t \in States \ {s, "conflict"} :
        ~IsAllowed(s, t) \/ (s = "cancelled" /\ t = "queued")
\* ... not even into `conflict`.
T1b_TerminalNotToConflict ==
    \A s \in Terminal \ {"conflict"} : ~IsAllowed(s, "conflict")
\* Every non-terminal state has a way out.
T2_NoNonTerminalSink ==
    \A s \in States \ Terminal : \E t \in States \ {s} : IsAllowed(s, t)
\* canRunAutomatically never covers a terminal state.
T3_AutoRunNotTerminal == AutoRun \cap Terminal = {}
\* Every state is reachable from `queued` in the table graph.
RECURSIVE ReachFrom(_, _)
ReachFrom(S, n) == IF n = 0 THEN S
                   ELSE ReachFrom(S \cup {t \in States : \E s \in S : IsAllowed(s, t)}, n - 1)
T4_AllReachable == ReachFrom({"queued"}, 14) = States
TableChecks == T1_TerminalAbsorbing /\ T1b_TerminalNotToConflict
               /\ T2_NoNonTerminalSink /\ T3_AutoRunNotTerminal /\ T4_AllReachable
=============================================================================
