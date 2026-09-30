#!/bin/sh
# Re-run every check behind ../README.md, one TLC run per property.
# Args of run_one.sh: INV MaxSteps MaxFaults MaxCrashes MaxUser EnableServerFail
set -e
cd "$(dirname "$0")"
for inv in CancelSticky CancelSticky_beginIntent CancelSticky_setIntent CancelSticky_setUploadReceipt \
           CancelSticky_coordinatorRetry CancelSticky_applyTerminal CancelSticky_other \
           NoFinalizeAfterCancel NoReadyAfterCancel SameOperationId BytesRetained \
           NoStrandedRunnable \
           T1_TerminalAbsorbing T1b_TerminalNotToConflict T2_NoNonTerminalSink \
           T3_AutoRunNotTerminal T4_AllReachable; do
  ./run_one.sh $inv 4
done
# liveness under weak fairness of the coordinator, timer, clock and server
./run_one.sh EventuallySettles 4
# the shipped fixes (ApplyFix = TRUE, i.e. the current code): same bounds
for inv in CancelSticky NoReadyAfterCancel NoStrandedRunnable NoFinalizeAfterCancel \
           SameOperationId BytesRetained T1_TerminalAbsorbing T2_NoNonTerminalSink T4_AllReachable; do
  TAG=fix FIX=TRUE ./run_one.sh $inv 4
done
TAG=fix FIX=TRUE ./run_one.sh EventuallySettles 4
# deeper bound for the properties that hold
for inv in SameOperationId BytesRetained; do TAG=d6 ./run_one.sh $inv 6 3 2 3; done
for inv in CancelSticky NoFinalizeAfterCancel NoStrandedRunnable; do TAG=fix_d6 FIX=TRUE ./run_one.sh $inv 6 3 2 3; done
