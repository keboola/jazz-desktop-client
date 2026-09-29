#!/bin/sh
# usage: run_one.sh INVARIANT [MaxSteps] [ListFail] [ListLag] [HeadUnk] [LostResp] [PutFail] [PrepFail] [MaxCrashes]
# Checks ONE invariant (plus TypeOK) and writes out/<NAME>.{cfg,log}; NAME = <INV>[_$TAG].
set -e
cd "$(dirname "$0")"
INV=$1; STEPS=${2:-16}; LF=${3:-TRUE}; LL=${4:-TRUE}; HU=${5:-TRUE}; LR=${6:-TRUE}
PF=${7:-TRUE}; PR=${8:-TRUE}; MC=${9:-2}
N=$INV${TAG:+_$TAG}
mkdir -p out
cat > out/$N.cfg <<CFG
CONSTANTS
    MaxSteps = $STEPS
    MaxFiles = 3
    MaxCrashes = $MC
    EnableListFail = $LF
    EnableListLag = $LL
    EnableHeadUncertain = $HU
    EnableLostResponse = $LR
    EnablePutFail = $PF
    EnablePrepFail = $PR
SPECIFICATION Spec
CONSTRAINT StepBound
INVARIANTS TypeOK $INV
CFG
cp ArtifactDelivery.tla out/
cd out
rc=0
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock \
  -metadir "states_$N" -config $N.cfg ArtifactDelivery.tla > $N.log 2>&1 || rc=$?
rm -rf "states_$N"
echo "== $N"; grep -E "is violated|No error|distinct states found|Error:" $N.log | head -3
# TLC exits 12/13 for a safety/liveness counterexample (the findings this model documents);
# any other nonzero status is a broken run (parse, config or evaluation error), not a result.
case $rc in 0|12|13) ;; *) echo "TLC failed with exit $rc, see $(pwd)/$N.log" >&2; exit "$rc" ;; esac
