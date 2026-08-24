#!/bin/bash
set -uo pipefail

# Terminal gate for the sandboxed-containers-operator test chain.
#
# Every test step in the chain runs best_effort: true so that a failure in one
# step does not stop the others from running. best_effort failures, however, do
# NOT fail the overall job -- so on their own the test steps could fail silently
# and the job would still report success.
#
# To make failures visible, each test step records its real outcome to
# ${SHARED_DIR}/osc-test-status/<step-name> as PASS, FAIL, or SKIP. This step is
# the ONLY non-best_effort step in the chain: it reads those markers and exits
# non-zero if any step recorded FAIL, so the overall job reports failure while
# every earlier step still had a chance to run.

STATUS_DIR="${SHARED_DIR}/osc-test-status"
mkdir -p "${ARTIFACT_DIR}"

if [[ ! -d "${STATUS_DIR}" ]]; then
    echo "No test status directory found at ${STATUS_DIR}; nothing to report."
    exit 0
fi

echo "Test step results:"
failed=()
shopt -s nullglob
for f in "${STATUS_DIR}"/*; do
    name=$(basename "$f")
    status=$(tr -d '[:space:]' < "$f" 2>/dev/null || echo "UNKNOWN")
    echo "  ${name}: ${status:-UNKNOWN}"
    if [[ "${status}" == "FAIL" ]]; then
        failed+=("${name}")
    fi
done
shopt -u nullglob

if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: the following test step(s) reported failure: ${failed[*]}"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"osc-tests-report\" tests=\"${#failed[@]}\" failures=\"${#failed[@]}\">"
        for n in "${failed[@]}"; do
            echo "  <testcase name=\"${n}\"><failure message=\"${n} reported FAIL\"/></testcase>"
        done
        echo '</testsuite>'
    } > "${ARTIFACT_DIR}/junit_osc_tests_report.xml"
    exit 1
fi

echo "All test steps passed or were skipped."
exit 0
