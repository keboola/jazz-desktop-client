#!/bin/sh
# One TLC run per invariant; logs in out/. Expected results are in ../README.md.
set -e
cd "$(dirname "$0")"
S=${STEPS:-24}
# Full adversary (all failure modes on, 2 crashes).
for INV in TypeOK DedupLemma ReceiptPointsToComplete NoDuplicateComplete OnDeliveredOnce \
           NoLiveObjectDeleted PendingClearedAfterReceipt QueueProgress; do
  ./run_one.sh $INV $S
done
# Restricted environments: show which fault each violation needs.
#                                           ListFail ListLag HeadUnk LostResp PutFail PrepFail Crashes
TAG=perfectlist ./run_one.sh NoDuplicateComplete        $S FALSE FALSE FALSE
TAG=perfectlist ./run_one.sh QueueProgress              $S FALSE FALSE FALSE
TAG=nocrash     ./run_one.sh QueueProgress              $S TRUE TRUE TRUE TRUE TRUE TRUE 0
TAG=nolostresp  ./run_one.sh NoLiveObjectDeleted        $S TRUE TRUE TRUE FALSE
TAG=nolostresp  ./run_one.sh QueueProgress              $S TRUE TRUE TRUE FALSE
