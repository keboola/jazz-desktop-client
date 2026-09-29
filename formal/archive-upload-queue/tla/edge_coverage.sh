#!/bin/sh
# Which isAllowed edges does any modelled code path take? Runs the clean
# configuration with TrackEdges = TRUE, dumps every state and prints the
# union of the `used` sets (out/used_edges.txt). Takes about a minute and
# writes a ~700 MB temporary dump, removed afterwards.
set -e
cd "$(dirname "$0")"
mkdir -p out
sed -e 's/TrackEdges = FALSE/TrackEdges = TRUE/' -e 's/^INVARIANTS .*/INVARIANTS TypeOK/' \
  ArchiveUploadQueue.cfg > out/EdgeCoverage.cfg
cp ArchiveUploadQueue.tla out/
cd out
rc=0
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock \
  -noGenerateSpecTE -dump edges -metadir states_edges -config EdgeCoverage.cfg ArchiveUploadQueue.tla \
  > EdgeCoverage.log 2>&1 || rc=$?
rm -rf states_edges
# TLC exits 12/13 for a safety/liveness counterexample (the findings this model documents);
# any other nonzero status is a broken run (parse, config or evaluation error), not a result.
case $rc in 0|12|13) ;; *) echo "TLC failed with exit $rc, see $(pwd)/EdgeCoverage.log" >&2; exit "$rc" ;; esac
grep -o '<<"[a-zA-Z]*", "[a-zA-Z]*">>' edges.dump | sort -u > used_edges.txt
rm -f edges.dump
grep -E "distinct states found" EdgeCoverage.log
echo "edges taken: $(wc -l < used_edges.txt)"; grep '<<"cancelled"' used_edges.txt
