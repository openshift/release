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

assert_fails() {
    local name=$1
    shift
    if "$@" >/dev/null 2>&1; then
        fail "${name}" "command unexpectedly succeeded"
    else
        pass "${name}"
    fi
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
NULL_LINK='[{"name":"nullable","state":"FAILURE","bucket":"fail","link":null}]'
EMPTY_LINK='[{"name":"empty","state":"FAILURE","bucket":"fail","link":""}]'
CHANGED_STATE='[{"name":"unit","state":"ERROR","bucket":"fail","link":"https://prow.example/view/100"}]'

pending=$(filter_failures "${FIRST_RUN}" head-a)
assert_json_equal "first poll schedules failure" "${FIRST_RUN}" "${pending}"
record_failures "${pending}" head-a

pending=$(filter_failures "${SAME_RUN}" head-a)
assert_json_equal "repeated poll suppresses evaluated run" '[]' "${pending}"

pending=$(filter_failures "${SAME_RUN}" head-b)
assert_json_equal "same linked run stays suppressed after head update" '[]' "${pending}"

pending=$(filter_failures "${CHANGED_STATE}" head-a)
assert_json_equal "material state transition schedules linked run" "${CHANGED_STATE}" "${pending}"
record_failures "${pending}" head-a

pending=$(filter_failures "${CHANGED_STATE}" head-a)
assert_json_equal "repeated transitioned state is suppressed" '[]' "${pending}"

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

record_failures "${NULL_LINK}" head-a
pending=$(filter_failures "${NULL_LINK}" head-b)
assert_json_equal "null URL uses changed head as identity" "${NULL_LINK}" "${pending}"

record_failures "${EMPTY_LINK}" head-a
pending=$(filter_failures "${EMPTY_LINK}" head-b)
assert_json_equal "empty URL uses changed head as identity" "${EMPTY_LINK}" "${pending}"

CONCURRENT='[]'
for index in $(seq 1 12); do
    failure=$(jq -cn --arg name "concurrent-${index}" --arg link "https://prow.example/view/concurrent-${index}" \
        '[{name:$name,state:"FAILURE",bucket:"fail",link:$link}]')
    CONCURRENT=$(jq -cn --argjson accumulated "${CONCURRENT}" --argjson failure "${failure}" \
        '$accumulated + $failure')
    record_failures "${failure}" head-a &
done
wait
pending=$(filter_failures "${CONCURRENT}" head-a)
assert_json_equal "concurrent records do not lose ledger updates" '[]' "${pending}"

MALFORMED_STATE="${STATE_DIR}/malformed.json"
printf '%s\n' '{not-json' > "${MALFORMED_STATE}"
assert_fails "malformed JSON state fails closed" \
    bash "${RESPONDER}" __ci_failure_state filter "${FIRST_RUN}" head-a "${MALFORMED_STATE}"
assert_json_equal "valid ledger remains readable after process restart" '[]' \
    "$(filter_failures "${SAME_RUN}" head-a)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
