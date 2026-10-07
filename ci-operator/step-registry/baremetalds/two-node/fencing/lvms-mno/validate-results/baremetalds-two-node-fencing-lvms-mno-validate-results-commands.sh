#!/bin/bash

set -euo pipefail

python3 - "${SHARED_DIR}/lvms-tnf-junit.xml" "${ARTIFACT_DIR}/skip-summary.txt" <<'PY'
import sys
import xml.etree.ElementTree as ET

junit_path, summary_path = sys.argv[1:]
root = ET.parse(junit_path).getroot()
cases = [element for element in root.iter()
         if element.tag in {"testcase", "testcases"} and element.get("name")]

skips = []
failures = []
passed = 0
for case in cases:
    name = case.get("name", "")
    skipped = case.find("skipped")
    if skipped is not None:
        skips.append((name, skipped.get("message", "")))
    elif case.find("failure") is not None or case.find("error") is not None:
        failures.append(name)
    else:
        passed += 1

with open(summary_path, "w", encoding="utf-8") as summary:
    summary.write(f"passed={passed} failed={len(failures)} skipped={len(skips)}\n")
    for name, reason in skips:
        summary.write(f"SKIPPED {name}: {reason}\n")
    for name in failures:
        summary.write(f"FAILED {name}\n")

print(open(summary_path, encoding="utf-8").read())
if not cases or not passed or failures or skips:
    for name, reason in skips:
        print(f"UNEXPECTED SKIP {name}: {reason}", file=sys.stderr)
    sys.exit(1)
PY
