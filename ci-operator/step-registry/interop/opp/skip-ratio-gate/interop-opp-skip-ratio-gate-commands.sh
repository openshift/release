#!/bin/bash
set -eux -o pipefail
shopt -s inherit_errexit

function Main () {
    typeset scanDir="${JUNIT_DIR:-${ARTIFACT_DIR}}"

    : "=== Skip-Ratio Health Gate ==="
    echo "Scan directory : ${scanDir}"
    echo "Max skip ratio : ${MAX_SKIP_RATIO}"
    echo ""

    typeset -a junitFiles=()
    mapfile -t junitFiles < <(find "${scanDir}" -name 'junit*.xml' -type f 2>/dev/null | sort)

    if [[ "${#junitFiles[@]}" -eq 0 ]]; then
        echo "ERROR: No junit*.xml files found in ${scanDir}"
        exit 1
    fi

    echo "Found ${#junitFiles[@]} junit file(s)."
    echo ""

    python3 - "${MAX_SKIP_RATIO}" "${ARTIFACT_DIR}" "${junitFiles[@]}" <<'PYEOF'
import sys
import os
import xml.etree.ElementTree as ET

max_skip_ratio = float(sys.argv[1])
artifact_dir = sys.argv[2]
junit_files = sys.argv[3:]

total_tests = 0
total_skipped = 0
total_failures = 0
file_stats = []

for fpath in junit_files:
    fname = os.path.basename(fpath)
    try:
        tree = ET.parse(fpath)
        root = tree.getroot()
    except ET.ParseError as e:
        print(f"WARNING: Malformed XML in {fname}, skipping: {e}")
        continue

    f_tests = 0
    f_skipped = 0
    f_failures = 0

    # Handle both <testsuites><testsuite>... and bare <testsuite>
    suites = []
    if root.tag == "testsuites":
        suites = root.findall("testsuite")
    elif root.tag == "testsuite":
        suites = [root]
    else:
        # Try to find any testsuite elements anywhere
        suites = root.iter("testsuite")

    for suite in suites:
        f_tests += int(suite.get("tests", 0))
        f_skipped += int(suite.get("skipped", 0))
        f_failures += int(suite.get("failures", 0))

    file_stats.append((fname, f_tests, f_skipped, f_failures))
    total_tests += f_tests
    total_skipped += f_skipped
    total_failures += f_failures

# Print summary table
header = f"{'File':<60s} {'Tests':>7s} {'Skipped':>8s} {'Failures':>9s}"
print(header)
print("-" * len(header))
for fname, t, s, f in file_stats:
    display = fname if len(fname) <= 60 else "..." + fname[-57:]
    print(f"{display:<60s} {t:>7d} {s:>8d} {f:>9d}")
print("-" * len(header))
print(f"{'TOTAL':<60s} {total_tests:>7d} {total_skipped:>8d} {total_failures:>9d}")
print()

if total_tests == 0:
    print("ERROR: Total test count is 0 — nothing was executed.")
    # Write a failing JUnit result
    gate_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<testsuite name="skip-ratio-gate" tests="1" failures="1" skipped="0">\n'
        '  <testcase name="skip-ratio-check">\n'
        '    <failure message="Total test count is 0">No tests were executed.</failure>\n'
        '  </testcase>\n'
        '</testsuite>\n'
    )
    with open(os.path.join(artifact_dir, "junit_skip_ratio_gate.xml"), "w") as f:
        f.write(gate_xml)
    sys.exit(1)

skip_ratio = total_skipped / total_tests
print(f"Skip ratio     : {skip_ratio:.4f}  ({total_skipped}/{total_tests})")
print(f"Max allowed    : {max_skip_ratio:.4f}")
print()

passed = skip_ratio <= max_skip_ratio
verdict = "PASS" if passed else "FAIL"
print(f"Verdict        : {verdict}")

# Generate JUnit XML for this gate check
if passed:
    gate_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<testsuite name="skip-ratio-gate" tests="1" failures="0" skipped="0">\n'
        f'  <testcase name="skip-ratio-check" />\n'
        '</testsuite>\n'
    )
else:
    gate_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<testsuite name="skip-ratio-gate" tests="1" failures="1" skipped="0">\n'
        '  <testcase name="skip-ratio-check">\n'
        f'    <failure message="Skip ratio {skip_ratio:.4f} exceeds threshold {max_skip_ratio:.4f}">'
        f'Observed {total_skipped} skipped out of {total_tests} total tests.'
        f'</failure>\n'
        '  </testcase>\n'
        '</testsuite>\n'
    )

with open(os.path.join(artifact_dir, "junit_skip_ratio_gate.xml"), "w") as f:
    f.write(gate_xml)

if not passed:
    sys.exit(1)
PYEOF
    true
}

Main "$@"
true
