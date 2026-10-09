#!/bin/bash

set -euo pipefail

python3 - "${SHARED_DIR}/lvms-tnf-junit.xml" "${ARTIFACT_DIR}/skip-summary.txt" <<'PY'
import sys
import xml.etree.ElementTree as ET

junit_path, summary_path = sys.argv[1:]
root = ET.parse(junit_path).getroot()
cases = [element for element in root.iter()
         if element.tag == "testcase" and element.get("name")]

# RapiDAST cannot run on the disconnected TNF cluster. Keep all other skips
# visible as failures so missing storage coverage does not silently pass.
expected_skip = (
    "[sig-storage] STORAGE Author:mmakwana-[OTP][LVMS] "
    "lvm.topolvm.io API should pass RapiDAST security scan"
)
expected_skips = []
unexpected_skips = []
failures = []
passed = 0
for case in cases:
    name = case.get("name", "")
    skipped = case.find("skipped")
    if skipped is not None:
        skip = (name, skipped.get("message", ""))
        if name == expected_skip:
            expected_skips.append(skip)
        else:
            unexpected_skips.append(skip)
    elif case.find("failure") is not None or case.find("error") is not None:
        failures.append(name)
    else:
        passed += 1

with open(summary_path, "w", encoding="utf-8") as summary:
    summary.write(f"passed={passed} failed={len(failures)} skipped={len(expected_skips) + len(unexpected_skips)}\n")
    for name, reason in expected_skips:
        summary.write(f"EXPECTED SKIP {name}{': ' + reason if reason else ''}\n")
    for name, reason in unexpected_skips:
        summary.write(f"UNEXPECTED SKIP {name}{': ' + reason if reason else ''}\n")
    for name in failures:
        summary.write(f"FAILED {name}\n")

print(open(summary_path, encoding="utf-8").read())
if not cases or not passed or failures or unexpected_skips:
    for name, reason in unexpected_skips:
        print(f"UNEXPECTED SKIP {name}: {reason}", file=sys.stderr)
    sys.exit(1)
PY
