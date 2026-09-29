#!/bin/sh
# usage: run_one.sh MODULE NAME "INVARIANTS" "CONSTANTS block"
# Checks the listed invariants (plus TypeOK) of MODULE and writes out/NAME.{cfg,log}.
set -e
cd "$(dirname "$0")"
MOD=$1; N=$2; INV=$3; CONSTS=$4
mkdir -p out
cat > out/$N.cfg <<CFG
CONSTANTS
$CONSTS
SPECIFICATION Spec
CONSTRAINT StepBound
INVARIANTS TypeOK $INV
CFG
cp $MOD.tla out/
cd out
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock \
  -metadir "states_$N" -config $N.cfg $MOD.tla > $N.log 2>&1 || true
rm -rf "states_$N"
printf '%-40s ' "$N"
grep -E "is violated|No error has been found|distinct states found|^Error:" $N.log | tr '\n' ' '
echo
