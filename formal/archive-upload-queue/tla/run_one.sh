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
rc=0
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock -noGenerateSpecTE \
  -dumpTrace json $N.json -metadir "states_$N" -config $N.cfg ArchiveUploadQueue.tla > $N.log 2>&1 || rc=$?
rm -rf "states_$N"
echo "== $N"; grep -E "is violated|No error|distinct states found|Error:|Temporal properties were violated" $N.log | head -3
# TLC exits 12/13 for a safety/liveness counterexample (the findings this model documents).
# The T1-T4 checks are constant-level (they inspect the isAllowed table, not a behaviour): TLC
# reports a FALSE one as exit 151 with "The invariant of X is equal to FALSE", which is a result
# too. Any other nonzero status is a broken run (parse, config or evaluation error).
if [ "$rc" -eq 151 ] && grep -q "^Error: The invariant of $INV is equal to FALSE" $N.log; then rc=0; fi
case $rc in 0|12|13) ;; *) echo "TLC failed with exit $rc, see $(pwd)/$N.log" >&2; exit "$rc" ;; esac
