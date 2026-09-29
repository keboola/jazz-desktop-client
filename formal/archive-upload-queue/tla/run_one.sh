#!/bin/sh
# usage: run_one.sh INVARIANT [MaxSteps] [MaxFaults] [MaxCrashes] [MaxUser] [EnableServerFail]
# Checks ONE invariant (plus TypeOK) and writes out/<NAME>.{cfg,log,json}; NAME = <INV>[_$TAG].
# INVARIANT=EventuallySettles checks the liveness property under FairSpec instead.
# FIX=TRUE checks the proposed fix (constant ApplyFix) instead of the current code.
set -e
cd "$(dirname "$0")"
INV=$1; STEPS=${2:-4}; MF=${3:-2}; MC=${4:-1}; MU=${5:-2}; SF=${6:-TRUE}
N=$INV${TAG:+_$TAG}
mkdir -p out
if [ "$INV" = "EventuallySettles" ]; then
  SPEC=FairSpec; CHECK="PROPERTY $INV"; CONSTR=""
else
  SPEC=Spec; CHECK="INVARIANTS TypeOK $INV"; CONSTR="CONSTRAINT StepBound"
fi
cat > out/$N.cfg <<CFG
CONSTANTS
    MaxSteps = $STEPS
    MaxFaults = $MF
    MaxCrashes = $MC
    MaxUser = $MU
    EnableServerFail = $SF
    TrackEdges = FALSE
    ApplyFix = ${FIX:-FALSE}
SPECIFICATION $SPEC
$CONSTR
$CHECK
CFG
cp ArchiveUploadQueue.tla out/
cd out
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE \
  -dumpTrace json $N.json -metadir "states_$N" -config $N.cfg ArchiveUploadQueue.tla > $N.log 2>&1 || true
rm -rf "states_$N"
echo "== $N"; grep -E "is violated|No error|distinct states found|Error:|Temporal properties were violated" $N.log | head -3
