#!/usr/bin/env python3
"""Compact printer for a TLC `-dumpTrace json` counterexample of ArchiveUploadQueue.

usage: trace.py out/<NAME>.json
Prints each action and only the variables it changed.
"""

import json
import sys

SKIP = {"used", "opId", "bytes"}


def main():
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
    acts = d["counterexample"]["action"]
    prev = acts[0][0][1]
    init = ", ".join(f"{k}={v}" for k, v in sorted(prev.items()) if k not in SKIP)
    print(f"  0 Init: {init}")
    for n, (_pre, act, post) in enumerate(acts, start=1):
        cur = post[1]
        diff = ", ".join(
            f"{k}={cur[k]}" for k in sorted(cur) if k not in SKIP and cur[k] != prev.get(k)
        )
        print(f"{n:3} {act['name']}: {diff}")
        prev = cur
    loop = d["counterexample"].get("loop")
    if loop:
        print(f"    (lasso: loops back to state {loop})")


main()
