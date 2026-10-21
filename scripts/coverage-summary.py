#!/usr/bin/env python3
"""Turn SwiftPM's code-coverage JSON into a Markdown table.

    swift test --enable-code-coverage
    python3 scripts/coverage-summary.py "$(swift test --show-codecov-path)"
"""
import json
import os
import sys

path = sys.argv[1]
root = os.path.join(os.getcwd(), "Sources") + os.sep

rows = []
covered_total = count_total = 0
for f in json.load(open(path))["data"][0]["files"]:
    name = f["filename"]
    if not name.startswith(root):
        continue
    lines = f["summary"]["lines"]
    covered_total += lines["covered"]
    count_total += lines["count"]
    rows.append((name[len(root):], lines["covered"], lines["count"]))

rows.sort(key=lambda r: (-(r[1] / r[2] if r[2] else 0), r[0]))
total = 100 * covered_total / count_total if count_total else 0
print(f"### Test coverage: {total:.1f}% of lines\n")
print("| File | Lines | Coverage |")
print("|---|---:|---:|")
for name, covered, count in rows:
    pct = 100 * covered / count if count else 0
    print(f"| `{name}` | {covered}/{count} | {pct:.0f}% |")
