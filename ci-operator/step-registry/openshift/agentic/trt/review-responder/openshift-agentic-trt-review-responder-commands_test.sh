#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESPONDER="${SCRIPT_DIR}/openshift-agentic-trt-review-responder-commands.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT
FAIL_RM=false

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file $1"
}

assert_no_file() {
    [[ ! -e "$1" ]] || fail "did not expect path $1"
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "expected '$1' to equal '$2'"
}

# Load the production git safety helpers without executing the responder's
# setup, network access, workers, polling loop, or exit traps.
load_production_helpers() {
    local helpers

    helpers=$(sed -n '/^read_pr_head() {/,/^note_push_failure() {/ {
        /^note_push_failure() {/q
        p
    }' "${RESPONDER}")
    eval "${helpers}"
    declare -F capture_round_baseline >/dev/null || fail "capture_round_baseline is not defined"
    declare -F recover_failed_round >/dev/null || fail "recover_failed_round is not defined"
}

setup_repo() {
    local name=$1

    CASE_ROOT="${TEST_ROOT}/${name}"
    REMOTE_REPO="${CASE_ROOT}/fork.git"
    WORK_REPO="${CASE_ROOT}/work"
    COMMAND_LOG="${CASE_ROOT}/commands.log"
    SETTINGS_DIR="${CASE_ROOT}/settings"
    mkdir -p "${SETTINGS_DIR}"

    command git init --quiet --initial-branch=feature "${WORK_REPO}"
    cd "${WORK_REPO}"
    command git config user.name test
    command git config user.email test@example.com
    printf 'baseline one\n' > one.txt
    printf 'baseline two\n' > two.txt
    printf 'runtime/\n' > .gitignore
    command git add .gitignore one.txt two.txt
    command git commit --quiet -m baseline
    printf 'previously published worker result\n' > earlier-success.txt
    command git add earlier-success.txt
    command git commit --quiet -m 'previous successful worker round'
    BASELINE_HEAD=$(command git rev-parse HEAD)
    command git clone --bare --quiet "${WORK_REPO}" "${REMOTE_REPO}"
    command git remote add fork https://github.com/example/fork.git

    mkdir -p artifacts/preexisting-dir runtime
    printf 'preexisting artifact\n' > artifacts/preexisting.log
    printf 'nested preexisting artifact\n' > artifacts/preexisting-dir/nested.log
    printf 'unusual preexisting artifact\n' > $'artifacts/preexisting\nartifact.log'
    ln -s preexisting.log artifacts/preexisting-link
    printf 'preexisting runtime input\n' > runtime/input

    FORK_REPO=example/fork
    PR_NUM=1
    UPSTREAM_REPO=example/upstream
    PR_HEAD_OWNER=example
    PR_HEAD_REPO=fork
    PR_HEAD_BRANCH=feature
    PR_HEAD_SHA="${BASELINE_HEAD}"
    EXPECTED_PR_HEAD_OWNER=example
    EXPECTED_PR_HEAD_REPO=fork
    EXPECTED_PR_HEAD_BRANCH=feature
    EXPECTED_PR_HEAD_REF=refs/heads/feature
    EXPECTED_REMOTE_HEAD="${BASELINE_HEAD}"
    # Production functions are loaded with eval, so make their reads of these
    # fixture globals explicit to static analysis as well.
    : "${FORK_REPO}" "${PR_NUM}" "${UPSTREAM_REPO}" "${PR_HEAD_OWNER}" \
        "${PR_HEAD_REPO}" "${PR_HEAD_BRANCH}" "${PR_HEAD_SHA}" \
        "${EXPECTED_PR_HEAD_OWNER}" "${EXPECTED_PR_HEAD_REPO}" \
        "${EXPECTED_PR_HEAD_BRANCH}" "${EXPECTED_PR_HEAD_REF}" "${EXPECTED_REMOTE_HEAD}"
    : > "${COMMAND_LOG}"
}

# The production helpers require the effective fork URL to stay HTTPS. Route
# only fetches to the local fixture while logging forbidden external actions.
git() {
    if [[ "$1" == "remote" && "$2" == "get-url" ]]; then
        printf '%s\n' 'https://github.com/example/fork.git'
    elif [[ "$1" == "fetch" ]]; then
        printf 'fetch\n' >> "${COMMAND_LOG}"
        command git fetch --quiet --no-tags --no-recurse-submodules \
            "${REMOTE_REPO}" "${*: -1}"
    elif [[ "$1" == "push" ]]; then
        printf 'push\n' >> "${COMMAND_LOG}"
        return 99
    else
        command git "$@"
    fi
}

rm() {
    if [[ "${FAIL_RM}" == "true" && "$*" == *untracked-by-worker.txt* ]]; then
        return 97
    fi
    command rm "$@"
}

gh() {
    printf 'gh %s\n' "$*" >> "${COMMAND_LOG}"
    if [[ "$1 $2" == "pr view" ]]; then
        printf '{"headRefName":"feature","headRefOid":"%s","headRepository":{"name":"fork"},"headRepositoryOwner":{"login":"example"}}\n' \
            "${BASELINE_HEAD}"
        return 0
    fi
    return 98
}

capture_fixture_baseline() {
    capture_expected_pr_head
    capture_round_baseline
    assert_eq "$(command git rev-parse HEAD)" "${BASELINE_HEAD}"
}

assert_dirty_next_checkout_fails() {
    if capture_expected_pr_head; then
        fail "verified-head checkout accepted failed-round worktree changes"
    fi
}

assert_recovered_and_retryable() {
    assert_eq "$(command git rev-parse HEAD)" "${BASELINE_HEAD}"
    assert_eq "$(command git symbolic-ref HEAD)" refs/heads/feature
    command git diff --quiet || fail "tracked worktree changes survived recovery"
    command git diff --cached --quiet || fail "staged changes survived recovery"
    assert_eq "$(<one.txt)" "baseline one"
    assert_eq "$(<two.txt)" "baseline two"
    assert_file artifacts/preexisting.log
    assert_file artifacts/preexisting-dir/nested.log
    assert_file $'artifacts/preexisting\nartifact.log'
    [[ -L artifacts/preexisting-link ]] || fail "preexisting artifact symlink was removed"
    assert_file artifacts/worker.log
    assert_file artifacts/worker-dir/nested.log
    [[ -L artifacts/worker-link ]] || fail "worker artifact symlink was removed"
    assert_file earlier-success.txt
    assert_file runtime/input
    assert_file runtime/worker-cache
    assert_no_file committed-by-worker.txt
    assert_no_file untracked-by-worker.txt
    assert_no_file worker-source-link
    assert_no_file $'worker\nsource.txt'

    # This is the operation that failed on the next polling iteration before
    # recovery existed. It must now re-fetch and check out the verified head.
    capture_expected_pr_head
    assert_eq "$(command git rev-parse HEAD)" "${BASELINE_HEAD}"
    [[ "$(command git --git-dir="${REMOTE_REPO}" rev-parse refs/heads/feature)" == "${BASELINE_HEAD}" ]] || \
        fail "remote branch changed"
    ! grep -qx 'push' "${COMMAND_LOG}" || fail "recovery attempted a push"
    ! grep -q '^gh pr comment' "${COMMAND_LOG}" || fail "recovery requested a retest"
}

make_worker_changes() {
    printf 'committed worker change\n' > one.txt
    printf 'worker commit\n' > committed-by-worker.txt
    command git add one.txt committed-by-worker.txt
    command git commit --quiet -m 'worker commit'
    printf 'unstaged worker change\n' > one.txt
    printf 'staged worker change\n' > two.txt
    command git add two.txt
    printf 'untracked worker change\n' > untracked-by-worker.txt
    printf 'worker artifact\n' > artifacts/worker.log
    mkdir -p artifacts/worker-dir
    printf 'nested worker artifact\n' > artifacts/worker-dir/nested.log
    ln -s worker.log artifacts/worker-link
    ln -s earlier-success.txt worker-source-link
    printf 'unusual worker source\n' > $'worker\nsource.txt'
    printf 'ignored worker cache\n' > runtime/worker-cache
}

test_review_failure_recovers_dirty_round() {
    setup_repo review-failure
    capture_fixture_baseline
    make_worker_changes

    # Reproduce the next-iteration failure that originally blocked retries.
    assert_dirty_next_checkout_fails
    recover_failed_round
    assert_recovered_and_retryable
}

test_ci_failure_recovers_dirty_round() {
    setup_repo ci-failure
    capture_fixture_baseline
    printf 'unstaged worker change\n' > one.txt
    printf 'staged worker change\n' > two.txt
    command git add two.txt
    printf 'untracked worker change\n' > untracked-by-worker.txt
    printf 'worker artifact\n' > artifacts/worker.log
    mkdir -p artifacts/worker-dir
    printf 'nested worker artifact\n' > artifacts/worker-dir/nested.log
    ln -s worker.log artifacts/worker-link
    ln -s earlier-success.txt worker-source-link
    printf 'unusual worker source\n' > $'worker\nsource.txt'
    printf 'ignored worker cache\n' > runtime/worker-cache

    recover_failed_round
    assert_recovered_and_retryable
}

test_ci_failure_discards_successful_review_work() {
    setup_repo review-success-ci-failure
    capture_fixture_baseline
    make_worker_changes

    # A successful review worker's local commit is still part of the same
    # unpushed round when the following CI worker fails.
    recover_failed_round
    assert_recovered_and_retryable
}

test_successful_round_is_not_recovered() {
    setup_repo success
    capture_fixture_baseline
    printf 'successful worker change\n' > one.txt
    command git add one.txt
    command git commit --quiet -m 'successful worker commit'
    successful_head=$(command git rev-parse HEAD)

    # Recovery is called only from the workers_succeeded=false branch. A
    # successful round remains available for the existing push path.
    [[ "${successful_head}" != "${BASELINE_HEAD}" ]] || fail "worker commit was not created"
    assert_eq "$(<one.txt)" "successful worker change"
}

test_recovery_fails_closed_on_branch_change() {
    setup_repo wrong-branch
    capture_fixture_baseline
    printf 'worker change\n' > one.txt
    command git switch --quiet -c unexpected-branch
    before=$(command git rev-parse HEAD)

    if recover_failed_round; then
        fail "recovery accepted a different checked-out branch"
    fi
    assert_eq "$(command git symbolic-ref HEAD)" refs/heads/unexpected-branch
    assert_eq "$(command git rev-parse HEAD)" "${before}"
    assert_eq "$(<one.txt)" "worker change"
    [[ "$(command git --git-dir="${REMOTE_REPO}" rev-parse refs/heads/feature)" == "${BASELINE_HEAD}" ]] || \
        fail "remote branch changed after failed recovery"
    ! grep -qx 'push' "${COMMAND_LOG}" || fail "failed recovery attempted a push"
}

test_recovery_reports_partial_cleanup_failure() {
    setup_repo cleanup-failure
    capture_fixture_baseline
    make_worker_changes
    FAIL_RM=true

    if recover_failed_round; then
        fail "recovery ignored an untracked-file removal failure"
    fi
    FAIL_RM=false
    assert_eq "$(command git rev-parse HEAD)" "${BASELINE_HEAD}"
    assert_file untracked-by-worker.txt
    [[ "$(command git --git-dir="${REMOTE_REPO}" rev-parse refs/heads/feature)" == "${BASELINE_HEAD}" ]] || \
        fail "remote branch changed after partial cleanup failure"
    ! grep -qx 'push' "${COMMAND_LOG}" || fail "partial cleanup failure attempted a push"
}

load_production_helpers
test_review_failure_recovers_dirty_round
test_ci_failure_recovers_dirty_round
test_ci_failure_discards_successful_review_work
test_successful_round_is_not_recovered
test_recovery_fails_closed_on_branch_change
test_recovery_reports_partial_cleanup_failure

echo "PASS: review responder failed-round recovery"
