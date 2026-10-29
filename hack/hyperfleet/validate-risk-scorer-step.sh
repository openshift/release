#!/bin/bash
# Usage: bash hack/hyperfleet/validate-risk-scorer-step.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO_ROOT}/ci-operator/step-registry/hyperfleet/risk-scorer/hyperfleet-risk-scorer-commands.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

assert_contains() {
    local name="$1" expected="$2" actual="$3"
    if echo "${actual}" | grep -q "${expected}"; then
        pass "${name}"
    else
        fail "${name}" "expected '${expected}' in output"
        echo "  Output: ${actual}"
    fi
}

# Builds a GitHub API /pulls/:n/files JSON response.
# Usage: make_files_json <additions_per_file> <deletions_per_file> <file1> [<file2> ...]
make_files_json() {
    local add="$1" del="$2"; shift 2
    local json="[" sep=""
    for f in "$@"; do
        json+="${sep}{\"filename\":\"${f}\",\"additions\":${add},\"deletions\":${del},\"status\":\"modified\"}"
        sep=","
    done
    json+="]"
    echo "${json}"
}

MOCK_BIN=""
SAVED_PATH=""

setup_mock() {
    local files_json="$1"
    MOCK_BIN=$(mktemp -d)
    SAVED_PATH="${PATH}"
    echo "${files_json}" > "${MOCK_BIN}/files.json"
    cat > "${MOCK_BIN}/curl" << 'EOF'
#!/bin/bash
MOCK_BIN="$(cd "$(dirname "$0")" && pwd)"
HAS_W=false
URL=""
for arg in "$@"; do
    [[ "${arg}" == "-w" ]] && HAS_W=true
    [[ "${arg}" == https://* ]] && URL="${arg%%\?*}"
done
if   [[ "${URL}" == */pulls/*/files ]];     then cat "${MOCK_BIN}/files.json"
elif [[ "${URL}" == */issues/*/labels/* ]]; then echo "{}"
elif [[ "${URL}" == */issues/*/labels ]];   then echo "[]"
elif [[ "${URL}" == */issues/*/comments ]]; then echo "[]"
elif [[ "${URL}" == */issues/comments/* ]]; then echo "{}"
else echo "{}"
fi
${HAS_W} && printf "\n200"
exit 0
EOF
    chmod +x "${MOCK_BIN}/curl"
    export PATH="${MOCK_BIN}:${PATH}"
}

cleanup_mock() {
    rm -rf "${MOCK_BIN}"
    export PATH="${SAVED_PATH}"
    MOCK_BIN=""
    SAVED_PATH=""
}

run_with_files() {
    local files_json="$1"
    setup_mock "${files_json}"
    local out
    out=$(GITHUB_TOKEN=test-token \
          PULL_NUMBER=1 \
          REPO_OWNER=openshift-hyperfleet \
          REPO_NAME=hyperfleet-api \
          bash "${SCRIPT}" 2>&1) || true
    cleanup_mock
    echo "${out}"
}

# =============================================================================
# Guard tests
# =============================================================================

test_guard_no_pull_number() {
    local out
    out=$(PULL_NUMBER="" bash "${SCRIPT}" 2>&1) || true
    assert_contains "guard/no-pull-number" "PULL_NUMBER not set" "${out}"
}

test_guard_wrong_owner() {
    local out
    out=$(PULL_NUMBER=1 REPO_OWNER=other-org bash "${SCRIPT}" 2>&1) || true
    assert_contains "guard/wrong-owner" "not an openshift-hyperfleet repo" "${out}"
}

# =============================================================================
# Scoring tests
#
# Score signals: size (+1 or +2), sensitive paths (+2), test coverage (+1 or +2)
# Thresholds:   0-1 = low | 2-3 = medium | 4+ = high
# =============================================================================

test_score_low_small_pr() {
    # 2 × (50 add + 50 del) = 200 lines, no sensitive paths, no Go → score 0 → low
    local files; files=$(make_files_json 50 50 "pkg/foo/bar.txt" "docs/readme.md")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/low-small-pr" "risk/low" "${out}"
}

test_score_medium_large_pr() {
    # 2 × (150 add + 150 del) = 600 lines (>500), no sensitive, no Go → score 2 → medium
    local files; files=$(make_files_json 150 150 "pkg/foo/bar.txt" "docs/readme.md")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/medium-large-pr" "risk/medium" "${out}"
}

test_score_medium_sensitive_path() {
    # 1 non-Go file in cmd/ (sensitive), 100 lines → score 0+2+0 = 2 → medium
    local files; files=$(make_files_json 50 50 "cmd/server/config.yaml")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/medium-sensitive-path" "risk/medium" "${out}"
}

test_score_high_no_tests() {
    # Go files in cmd/ (sensitive), no _test.go → score 0+2+2 = 4 → high
    local files; files=$(make_files_json 50 50 "cmd/server/main.go" "cmd/worker/worker.go")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/high-no-tests" "risk/high" "${out}"
}

test_score_low_go_full_tests() {
    # Go file and its _test.go in the same package → test coverage complete → score 0 → low
    local files; files=$(make_files_json 30 30 "pkg/foo/bar.go" "pkg/foo/bar_test.go")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/low-go-full-tests" "risk/low" "${out}"
}

test_score_medium_partial_tests() {
    # cmd/server covered by _test.go, cmd/worker uncovered → 0+2(sensitive)+1(partial) = 3 → medium
    local files; files=$(make_files_json 30 30 \
        "cmd/server/main.go" "cmd/server/main_test.go" "cmd/worker/worker.go")
    local out; out=$(run_with_files "${files}")
    assert_contains "score/medium-partial-tests" "risk/medium" "${out}"
}

# =============================================================================
# Main
# =============================================================================

test_guard_no_pull_number
test_guard_wrong_owner
test_score_low_small_pr
test_score_medium_large_pr
test_score_medium_sensitive_path
test_score_high_no_tests
test_score_low_go_full_tests
test_score_medium_partial_tests

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
