#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESPONDER="${REPO_ROOT}/ci-operator/step-registry/openshift/agentic/trt/review-responder/openshift-agentic-trt-review-responder-commands.sh"
STATE_DIR=$(mktemp -d)
STATE_FILE="${STATE_DIR}/evaluated.json"
trap 'rm -rf "${STATE_DIR}"' EXIT

PASS=0
FAIL=0

pass() {
    echo "PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "FAIL: $1 — $2"
    FAIL=$((FAIL + 1))
}

filter_failures() {
    bash "${RESPONDER}" __ci_failure_state filter "$1" "$2" "${STATE_FILE}"
}

record_failures() {
    bash "${RESPONDER}" __ci_failure_state record "$1" "$2" "${STATE_FILE}"
}

assert_json_equal() {
    local name=$1
    local expected=$2
    local actual=$3
    if jq -e -n --argjson expected "${expected}" --argjson actual "${actual}" \
        '$expected == $actual' >/dev/null; then
        pass "${name}"
    else
        fail "${name}" "expected ${expected}, got ${actual}"
    fi
}

FIRST_RUN='[{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://prow.example/view/100"}]'
SAME_RUN='[{"bucket":"fail","link":"https://prow.example/view/100","state":"FAILURE","name":"unit"}]'
NEW_RUN='[{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://prow.example/view/101"}]'
OLD_AND_NEW_RUNS='[{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://prow.example/view/100"},{"name":"unit","state":"FAILURE","bucket":"fail","link":"https://prow.example/view/101"}]'
NO_LINK='[{"name":"external","state":"FAILURE","bucket":"fail"}]'

pending=$(filter_failures "${FIRST_RUN}" head-a)
assert_json_equal "first poll schedules failure" "${FIRST_RUN}" "${pending}"
record_failures "${pending}" head-a

pending=$(filter_failures "${SAME_RUN}" head-a)
assert_json_equal "repeated poll suppresses evaluated run" '[]' "${pending}"

pending=$(filter_failures "${SAME_RUN}" head-b)
assert_json_equal "same linked run stays suppressed after head update" '[]' "${pending}"

pending=$(filter_failures "${NEW_RUN}" head-a)
assert_json_equal "new run URL schedules same job name" "${NEW_RUN}" "${pending}"

pending=$(filter_failures "${OLD_AND_NEW_RUNS}" head-a)
assert_json_equal "mixed poll passes only unseen run to worker" "${NEW_RUN}" "${pending}"

pending=$(filter_failures "${NO_LINK}" head-a)
assert_json_equal "unlinked failure first poll schedules" "${NO_LINK}" "${pending}"
record_failures "${pending}" head-a

pending=$(filter_failures "${NO_LINK}" head-a)
assert_json_equal "unlinked failure repeats are suppressed on same head" '[]' "${pending}"

pending=$(filter_failures "${NO_LINK}" head-b)
assert_json_equal "unlinked failure on new head schedules" "${NO_LINK}" "${pending}"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
