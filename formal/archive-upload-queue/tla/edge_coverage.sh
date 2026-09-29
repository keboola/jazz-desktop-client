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
java -XX:+UseParallelGC -cp "${TLA2TOOLS:-$HOME/tools/tla/tla2tools.jar}" tlc2.TLC -workers auto -deadlock \
  -noGenerateSpecTE -dump edges -metadir states_edges -config EdgeCoverage.cfg ArchiveUploadQueue.tla \
  > EdgeCoverage.log 2>&1 || true
rm -rf states_edges
grep -o '<<"[a-zA-Z]*", "[a-zA-Z]*">>' edges.dump | sort -u > used_edges.txt
rm -f edges.dump
grep -E "distinct states found" EdgeCoverage.log
echo "edges taken: $(wc -l < used_edges.txt)"; grep '<<"cancelled"' used_edges.txt
