#!/usr/bin/env python3
"""Compact a TLC counterexample from out/<NAME>.log: one line per step with the action
name and the chosen variables.  usage: trace.py out/NAME.log [var ...]"""
import re
import sys

path, wanted = sys.argv[1], sys.argv[2:] or ["rec", "live", "pc"]
text = open(path).read()
if "is violated" not in text:
    print("no counterexample in", path)
    sys.exit(0)
for block in re.split(r"\n(?=State \d+: )", text)[1:]:
    head, _, body = block.partition("\n")
    m = re.match(r"State (\d+): <(\w+)", head)
    step, action = (m.group(1), m.group(2)) if m else ("?", head)
    values = {}
    for var in re.finditer(r"^/\\ (\w+) = (.*?)(?=\n/\\ |\n\n|\Z)", body, re.S | re.M):
        values[var.group(1)] = " ".join(var.group(2).split())
    shown = "  ".join(f"{k}={values[k]}" for k in wanted if k in values)
    print(f"{step:>3} {action:<12} {shown}")
