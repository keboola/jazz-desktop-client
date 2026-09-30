------------------------- MODULE ArtifactDelivery -------------------------
(***************************************************************************)
(* Finite model of the archive-artifact projection to Keboola Storage     *)
(* Files (narration audio + screenshots) in keboola/jazz-desktop-client.  *)
(*                                                                         *)
(* Every action mirrors a piece of the Swift code (file:line at the time  *)
(* of writing, paths relative to macos/Sources):                          *)
(*   JazzCaptureCore/JazzArchiveDeliveryQueue.swift                        *)
(*       pending() 120-131 (sorted by queuedAt, artifactId)                *)
(*       markDelivered() 133-177 (receipt writeOnce 167, remove pending    *)
(*       175; the receipt-exists branch 143-157 also removes pending: F1)  *)
(*   JazzCapture/ArchiveArtifactUploader.swift                             *)
(*       drainOnce() 100-161, existingRemoteId() 163-180,                  *)
(*       finish() 182-199                                                  *)
(*   JazzCaptureCore/NarrationDedup.swift decide() 42-56                   *)
(*   JazzCapture/KeboolaClient.swift listFiles() 228-245 ([] on error),    *)
(*       gcsObjectExists() 252-264 (HEAD: true/false/nil),                 *)
(*       deleteFile() 270-273                                              *)
(*                                                                         *)
(* One uploader actor (passes are sequential). A crash can happen between *)
(* any two steps; the relaunch starts a fresh pass from on-disk state.    *)
(* Abstracted: bytes/digests, archive-read failure (a deliberate "wait"), *)
(* backoff timing, status publishing, the `created` timestamp (file ids   *)
(* are allocated in creation order, so "oldest first" = lowest id).       *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets, Sequences, TLC

CONSTANTS
    MaxSteps,            \* depth bound (state constraint)
    MaxFiles,            \* Storage file ids 1..MaxFiles
    MaxCrashes,          \* crashes/relaunches allowed
    EnableListFail,      \* listFiles returns [] on a transport/decode error
    EnableListLag,       \* listing may miss recently created files
    EnableHeadUncertain, \* HEAD answers nil (403/5xx/timeout)
    EnableLostResponse,  \* PUT reaches GCS but the response is lost
    EnablePutFail,       \* PUT fails before any bytes land
    EnablePrepFail       \* prepareFile fails

Arts  == {"a1", "a2"}
Order == <<"a1", "a2">>            \* pending() sort order (queuedAt, artifactId)
Ids   == 1..MaxFiles
None  == 0
St    == {"none", "prepared", "complete", "deleted"}
PCs   == {"idle", "list", "prep", "put", "md1", "md2", "notify"}

VARIABLES
    pending,     \* local: pending/<art>.json exists
    receipt,     \* local: delivered/<art>.json -> remoteFileId (0 = absent)
    files,       \* remote Storage: id -> [art, st]
    nextId,      \* next Storage file id to mint
    pc,          \* uploader program counter
    items,       \* in-memory snapshot of pending() for this pass
    idx,         \* index of the current item
    rid,         \* remote id handed to finish()
    cur,         \* id returned by prepareFile
    notified,    \* ghost: onDelivered call count per artifact
    liveDeleted, \* ghost: a Storage record with real bytes was deleted
    dedupOk,     \* ghost: every NarrationDedup decision satisfied its lemma
    lastPass,    \* ghost: how the last pass ended ("ok"/"fail"/"crash"/"none")
    crashes,
    steps

vars == <<pending, receipt, files, nextId, pc, items, idx, rid, cur, notified,
          liveDeleted, dedupOk, lastPass, crashes, steps>>

NoFile == [art |-> "a1", st |-> "none"]

TypeOK ==
    /\ pending \subseteq Arts
    /\ receipt \in [Arts -> {None} \cup Ids]
    /\ files \in [Ids -> [art : Arts, st : St]]
    /\ nextId \in 1..(MaxFiles + 1)
    /\ pc \in PCs
    /\ notified \in [Arts -> Nat]
    /\ liveDeleted \in BOOLEAN /\ dedupOk \in BOOLEAN
    /\ lastPass \in {"none", "ok", "fail", "crash"}

Init ==
    /\ pending = Arts                 \* both artifacts enqueued (enqueue 90-118)
    /\ receipt = [a \in Arts |-> None]
    /\ files = [i \in Ids |-> NoFile]
    /\ nextId = 1
    /\ pc = "idle"
    /\ items = <<>> /\ idx = 1 /\ rid = None /\ cur = None
    /\ notified = [a \in Arts |-> 0]
    /\ liveDeleted = FALSE /\ dedupOk = TRUE
    /\ lastPass = "none" /\ crashes = 0 /\ steps = 0

Cur == items[idx]
Complete(a) == {i \in Ids : files[i].art = a /\ files[i].st = "complete"}
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
OldestComplete(a) == IF Complete(a) = {} THEN None ELSE Min(Complete(a))

\* A pass ends early: drainOnce() `return false` (any throw/conflict).
PassFail ==
    /\ pc' = "idle" /\ lastPass' = "fail"
    /\ UNCHANGED <<items, idx, rid, cur>>

(* drainOnce 101-106: snapshot pending(), sorted.                          *)
StartPass ==
    /\ pc = "idle" /\ pending # {}
    /\ items' = SelectSeq(Order, LAMBDA x : x \in pending)
    /\ idx' = 1 /\ pc' = "list"
    /\ UNCHANGED <<pending, receipt, files, nextId, rid, cur, notified,
                   liveDeleted, dedupOk, lastPass, crashes>>

(* existingRemoteId 163-180 + listFiles 228-245 + gcsObjectExists +        *)
(* NarrationDedup.decide 42-56 + deleteFile of every dangling id (178).    *)
Visible(a) == {i \in Ids : i < nextId /\ files[i].art = a
                            /\ files[i].st \in {"prepared", "complete"}}
Truth(i) == IF files[i].st = "complete" THEN "yes" ELSE "no"
Listings(a) ==
    (IF EnableListLag THEN SUBSET Visible(a) ELSE {Visible(a)})
    \cup (IF EnableListFail THEN {{}} ELSE {})
Probes(L) ==
    IF EnableHeadUncertain
    THEN {p \in [L -> {"yes", "no", "unk"}] : \A i \in L : p[i] \in {Truth(i), "unk"}}
    ELSE {[i \in L |-> Truth(i)]}

List ==
    /\ pc = "list"
    /\ \E L \in Listings(Cur) : \E p \in Probes(L) :
        LET yes   == {i \in L : p[i] = "yes"}
            dang  == {i \in L : p[i] = "no"}
            reuse == IF yes = {} THEN None ELSE Min(yes)   \* first complete, oldest first
        IN /\ files' = [i \in Ids |-> IF i \in dang
                                      THEN [files[i] EXCEPT !.st = "deleted"]
                                      ELSE files[i]]
           /\ liveDeleted' = (liveDeleted \/ \E i \in dang : files[i].st = "complete")
           \* Safety lemma of the pure decide(): reuse and delete are disjoint,
           \* and only records whose HEAD said 404 are deleted.
           /\ dedupOk' = (dedupOk /\ reuse \notin dang
                          /\ \A i \in dang : p[i] = "no"
                          /\ (reuse # None => p[reuse] = "yes"))
           /\ IF reuse # None
              THEN pc' = "md1" /\ rid' = reuse
              ELSE pc' = "prep" /\ rid' = rid
    /\ UNCHANGED <<pending, receipt, nextId, items, idx, cur, notified, lastPass, crashes>>

(* drainOnce 126-133: prepareFile (mints a record, no bytes yet).          *)
PrepOk ==
    /\ pc = "prep" /\ nextId <= MaxFiles
    /\ files' = [files EXCEPT ![nextId] = [art |-> Cur, st |-> "prepared"]]
    /\ cur' = nextId /\ nextId' = nextId + 1 /\ pc' = "put"
    /\ UNCHANGED <<pending, receipt, items, idx, rid, notified, liveDeleted, dedupOk,
                   lastPass, crashes>>
PrepFail ==
    /\ pc = "prep" /\ EnablePrepFail /\ PassFail
    /\ UNCHANGED <<pending, receipt, files, nextId, notified, liveDeleted, dedupOk, crashes>>

(* drainOnce 142-152: PUT succeeds -> finish(item, prepared.id).           *)
PutOk ==
    /\ pc = "put"
    /\ files' = [files EXCEPT ![cur].st = "complete"]
    /\ rid' = cur /\ pc' = "md1"
    /\ UNCHANGED <<pending, receipt, nextId, items, idx, cur, notified, liveDeleted, dedupOk,
                   lastPass, crashes>>
(* drainOnce 153-156: PUT threw before bytes landed -> try? deleteFile.    *)
PutFail ==
    /\ pc = "put" /\ EnablePutFail
    /\ \E delOk \in BOOLEAN :
        files' = IF delOk THEN [files EXCEPT ![cur].st = "deleted"] ELSE files
    /\ PassFail
    /\ UNCHANGED <<pending, receipt, nextId, notified, liveDeleted, dedupOk, crashes>>
(* drainOnce 153-156 when the object DID land (response lost / timeout     *)
(* after upload): the catch deletes a record that has real bytes.          *)
PutLostResponse ==
    /\ pc = "put" /\ EnableLostResponse
    /\ \E delOk \in BOOLEAN :
        /\ files' = [files EXCEPT ![cur].st = IF delOk THEN "deleted" ELSE "complete"]
        /\ liveDeleted' = (liveDeleted \/ delOk)
    /\ PassFail
    /\ UNCHANGED <<pending, receipt, nextId, notified, dedupOk, crashes>>

(* finish 182-199 -> markDelivered 133-167.                                *)
MD1 ==
    /\ pc = "md1"
    /\ IF receipt[Cur] # None
       THEN IF receipt[Cur] = rid
            THEN /\ pc' = "md2"                \* F1 fix: finish the pending removal
                 /\ UNCHANGED <<receipt, lastPass, items, idx, rid, cur>>
            ELSE /\ PassFail                   \* 147-148: conflict -> finish false
                 /\ UNCHANGED receipt
       ELSE IF Cur \notin pending
            THEN PassFail /\ UNCHANGED receipt \* 158-160: missing
            ELSE /\ receipt' = [receipt EXCEPT ![Cur] = rid]   \* 167 writeOnce
                 /\ pc' = "md2"
                 /\ UNCHANGED <<lastPass, items, idx, rid, cur>>
    /\ UNCHANGED <<pending, files, nextId, notified, liveDeleted, dedupOk, crashes>>
(* markDelivered 175 (and 153-155, the F1 fix in the receipt-exists        *)
(* branch): remove pending/<art>.json, idempotently.                       *)
MD2 ==
    /\ pc = "md2"
    /\ pending' = pending \ {Cur}
    /\ pc' = "notify"
    /\ UNCHANGED <<receipt, files, nextId, items, idx, rid, cur, notified, liveDeleted,
                   dedupOk, lastPass, crashes>>
(* finish 186: onDelivered(item, remoteId); then the loop continues.       *)
Notify ==
    /\ pc = "notify"
    /\ notified' = [notified EXCEPT ![Cur] = @ + 1]
    /\ IF idx = Len(items)
       THEN pc' = "idle" /\ lastPass' = "ok" /\ idx' = idx
       ELSE pc' = "list" /\ idx' = idx + 1 /\ lastPass' = lastPass
    /\ UNCHANGED <<pending, receipt, files, nextId, items, rid, cur, liveDeleted, dedupOk,
                   crashes>>

(* Process crash anywhere inside a pass; relaunch = next StartPass.       *)
Crash ==
    /\ pc # "idle" /\ crashes < MaxCrashes
    /\ pc' = "idle" /\ lastPass' = "crash" /\ crashes' = crashes + 1
    /\ UNCHANGED <<pending, receipt, files, nextId, items, idx, rid, cur, notified,
                   liveDeleted, dedupOk>>

Next ==
    /\ steps' = steps + 1
    /\ \/ StartPass \/ List \/ PrepOk \/ PrepFail \/ PutOk \/ PutFail \/ PutLostResponse
       \/ MD1 \/ MD2 \/ Notify \/ Crash

Spec == Init /\ [][Next]_vars
StepBound == steps <= MaxSteps

(* ------------------------------ invariants ----------------------------- *)
\* At most one complete Storage file per artifact.
NoDuplicateComplete == \A a \in Arts : Cardinality(Complete(a)) <= 1
\* onDelivered (-> onSegmentReady -> live BDM turn) fires at most once.
OnDeliveredOnce == \A a \in Arts : notified[a] <= 1
\* No Storage record that holds real bytes is ever deleted.
NoLiveObjectDeleted == ~liveDeleted
\* After a pass that drainOnce() reports as complete, nothing that already has
\* a receipt is still pending.
PendingClearedAfterReceipt ==
    (pc = "idle" /\ lastPass = "ok") => \A a \in Arts : ~(a \in pending /\ receipt[a] # None)
\* Safety approximation of "one item never blocks the queue forever": between
\* passes, a pending item with a receipt must be re-finishable under a PERFECT
\* network, i.e. dedup would pick exactly the receipt's file. Otherwise every
\* future pass hits the conflict at 147-148 and returns false before reaching
\* the items sorted after it.
QueueProgress ==
    pc = "idle" => \A a \in pending : receipt[a] # None => OldestComplete(a) = receipt[a]
\* A receipt always names a complete file of the same artifact.
ReceiptPointsToComplete ==
    \A a \in Arts : receipt[a] # None =>
        files[receipt[a]].st = "complete" /\ files[receipt[a]].art = a
\* NarrationDedup.decide lemma (reuse/delete disjoint; deletes only HEAD-404).
DedupLemma == dedupOk
=============================================================================
