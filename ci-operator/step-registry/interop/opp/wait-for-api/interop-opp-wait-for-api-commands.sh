#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# JUnit result for this gate. The aggregated junit_operator.xml row for a
# failed step carries an empty message, so without a per-step carrier a
# timeout renders as a bare red step and triage has to open the build log.
_suite="lp-interop--OPP--wait-for-api"
_junit_file="${ARTIFACT_DIR:-/tmp}/junit_${_suite}.xml"
_junit_emitted=0
_junit_write() {
    # $1 = pass|fail, $2 = outcome text (also the failure message)
    if (( _junit_emitted )); then
        return 0
    fi
    _junit_emitted=1
    local status="$1" text="$2" failures=0 case_body=""
    if [[ "${status}" == "fail" ]]; then
        failures=1
        case_body=$(printf '\n    <failure message="%s">%s</failure>' "${text}" "${text}")
    fi
    if ! mkdir -p "$(dirname "${_junit_file}")"; then
        echo "JUNIT CONTRACT VIOLATION: carrier write failed: ${_junit_file}" >&2
        return 0
    fi
    if ! {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<testsuite name="%s" tests="1" failures="%s">\n' "${_suite}" "${failures}"
        printf '  <testcase name="cluster-api-reachable" classname="interop.opp.wait-for-api">%s\n  </testcase>\n' "${case_body}"
        printf '</testsuite>\n'
    } > "${_junit_file}"; then
        echo "JUNIT CONTRACT VIOLATION: carrier write failed: ${_junit_file}" >&2
    fi
    return 0
}
_on_exit() {
    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        _junit_write pass "cluster API reachable"
    else
        _junit_write fail "cluster API not reachable after ${API_WAIT_RETRIES:-unknown} attempt(s)"
    fi
    return 0
}
trap _on_exit EXIT

echo "Waiting for cluster API to become reachable..."
REQUIRED_CONSECUTIVE_SUCCESSES=5
CONSECUTIVE_SUCCESSES=0
for i in $(seq 1 "${API_WAIT_RETRIES}"); do
    if oc get --raw=/version &>/dev/null; then
        CONSECUTIVE_SUCCESSES=$((CONSECUTIVE_SUCCESSES + 1))
        if [[ "${CONSECUTIVE_SUCCESSES}" -ge "${REQUIRED_CONSECUTIVE_SUCCESSES}" ]]; then
            echo "Cluster API is reachable."
            exit 0
        fi
    else
        CONSECUTIVE_SUCCESSES=0
        echo "  Attempt ${i}/${API_WAIT_RETRIES}: API not reachable, retrying in ${API_WAIT_DELAY}s..."
    fi
    sleep "${API_WAIT_DELAY}"
done
echo "ERROR: Cluster API not reachable after $((API_WAIT_RETRIES * API_WAIT_DELAY))s"
exit 1
