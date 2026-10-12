#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
COMMANDS_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/openshift-qe/orion/openshift-qe-orion-commands.sh"
FUNCTIONS_FILE=$(mktemp)
TEST_STATE_DIR=$(mktemp -d)
TEST_WORK_DIR="${TEST_STATE_DIR}/work"
trap 'rm -f "$FUNCTIONS_FILE"; rm -rf "$TEST_STATE_DIR"' EXIT
mkdir "$TEST_WORK_DIR"

# Load the production functions without executing the CI step.
sed '/^# Main execution$/,$d' "$COMMANDS_SCRIPT" > "$FUNCTIONS_FILE"
# shellcheck source=/dev/null
source "$FUNCTIONS_FILE"
set +x
cd "$TEST_WORK_DIR"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected=$1 actual=$2 message=$3
  [[ "$actual" == "$expected" ]] || fail "$message: expected '$expected', got '$actual'"
}

reset_mocks() {
  MAX_RETRIES=3
  ORION_REPO=https://example.invalid/orion.git
  export MAX_RETRIES ORION_REPO
  printf '0\n' > "${TEST_STATE_DIR}/git_calls"
  printf '0\n' > "${TEST_STATE_DIR}/clone_calls"
  printf '0\n' > "${TEST_STATE_DIR}/sort_calls"
  : > "${TEST_STATE_DIR}/clone_args"
  ls_remote_results=()
  clone_results=(PASS PASS PASS)
  sort_results=(PASS PASS PASS)
}

increment_count() {
  local counter_file=$1 count
  count=$(<"$counter_file")
  count=$((count + 1))
  printf '%s\n' "$count" > "$counter_file"
  printf '%s\n' "$count"
}

read_count() {
  local counter_file=$1
  cat "$counter_file"
}

sleep() {
  :
}

sort() {
  local sort_calls result
  sort_calls=$(increment_count "${TEST_STATE_DIR}/sort_calls")
  result=${sort_results[$((sort_calls - 1))]}
  if [[ "$result" == FAIL ]]; then
    return 1
  fi
  command sort "$@"
}

git() {
  case "$1" in
    ls-remote)
      local git_calls result
      git_calls=$(increment_count "${TEST_STATE_DIR}/git_calls")
      result=${ls_remote_results[$((git_calls - 1))]}
      if [[ "$result" == FAIL ]]; then
        return 1
      fi
      printf '%b' "$result"
      ;;
    check-ref-format)
      command git "$@"
      ;;
    clone)
      local clone_calls result
      clone_calls=$(increment_count "${TEST_STATE_DIR}/clone_calls")
      printf '%s\n' "$*" >> "${TEST_STATE_DIR}/clone_args"
      result=${clone_results[$((clone_calls - 1))]}
      [[ "$result" == PASS ]]
      ;;
    *)
      fail "unexpected git invocation: $*"
      ;;
  esac
}

test_git_failure_then_success() {
  reset_mocks
  ls_remote_results=(FAIL '1\trefs/tags/v1.2.3\n')

  local actual
  actual=$(discover_latest_orion_tag)

  assert_eq v1.2.3 "$actual" "eventual discovery result"
  assert_eq 2 "$(read_count "${TEST_STATE_DIR}/git_calls")" "discovery attempt count"
}

test_repeated_git_failure() {
  reset_mocks
  ls_remote_results=(FAIL FAIL FAIL)

  local output
  if output=$(discover_latest_orion_tag 2>&1); then
    fail "repeated git failure unexpectedly succeeded"
  fi

  [[ "$output" == *"failed to discover a valid Orion tag after 3 attempts"* ]] ||
    fail "missing final discovery error: $output"
  assert_eq 3 "$(read_count "${TEST_STATE_DIR}/git_calls")" "exhausted discovery attempt count"
}

test_pipeline_failure_then_success() {
  reset_mocks
  ls_remote_results=('1\trefs/tags/v1.2.3\n' '1\trefs/tags/v1.2.3\n')
  sort_results=(FAIL PASS)

  local actual diagnostics
  diagnostics="${TEST_STATE_DIR}/pipeline_diagnostics"
  actual=$(discover_latest_orion_tag 2>"$diagnostics")

  assert_eq v1.2.3 "$actual" "eventual discovery result after pipeline failure"
  grep -q "Orion tag discovery pipeline failed (attempt 1/3)." "$diagnostics" ||
    fail "missing pipeline failure diagnostic"
  assert_eq 2 "$(read_count "${TEST_STATE_DIR}/git_calls")" "pipeline retry discovery attempt count"
  assert_eq 2 "$(read_count "${TEST_STATE_DIR}/sort_calls")" "pipeline retry sort attempt count"
}

test_empty_discovery() {
  reset_mocks
  ls_remote_results=('' '' '')

  local output
  if output=$(discover_latest_orion_tag 2>&1); then
    fail "empty discovery unexpectedly succeeded"
  fi

  [[ "$output" == *"returned no valid tag"* ]] || fail "missing empty discovery error: $output"
  assert_eq 3 "$(read_count "${TEST_STATE_DIR}/git_calls")" "empty discovery attempt count"
}

test_invalid_discovery() {
  reset_mocks
  ls_remote_results=('1\trefs/tags/bad tag\n' '1\trefs/tags/bad tag\n' '1\trefs/tags/bad tag\n')

  if discover_latest_orion_tag >/dev/null 2>&1; then
    fail "invalid discovery unexpectedly succeeded"
  fi

  assert_eq 3 "$(read_count "${TEST_STATE_DIR}/git_calls")" "invalid discovery attempt count"
}

test_annotated_and_version_tag_ordering() {
  reset_mocks
  ls_remote_results=('1\trefs/tags/v1.9.0\n2\trefs/tags/v1.10.0\n3\trefs/tags/v1.10.0^{}\n4\trefs/tags/v1.2.11\n')

  local actual
  actual=$(discover_latest_orion_tag)

  assert_eq v1.10.0 "$actual" "version-sorted annotated tag result"
  assert_eq 1 "$(read_count "${TEST_STATE_DIR}/git_calls")" "successful discovery attempt count"
}

test_clone_rejects_empty_tag() {
  reset_mocks

  if clone_orion "" >/dev/null 2>&1; then
    fail "clone with empty branch unexpectedly succeeded"
  fi

  assert_eq 0 "$(read_count "${TEST_STATE_DIR}/clone_calls")" "clone invocation count for empty branch"
  assert_eq "" "$(<"${TEST_STATE_DIR}/clone_args")" "clone arguments for empty branch"
}

test_clone_failure_then_success() {
  reset_mocks
  clone_results=(FAIL PASS)

  local diagnostics expected_args actual_args
  diagnostics="${TEST_STATE_DIR}/clone_diagnostics"
  clone_orion v1.2.3 2>"$diagnostics"
  expected_args=$'clone -q --branch v1.2.3 https://example.invalid/orion.git --depth 1\nclone -q --branch v1.2.3 https://example.invalid/orion.git --depth 1'
  actual_args=$(<"${TEST_STATE_DIR}/clone_args")

  grep -q "git clone failed (attempt 1/3), retrying in 10s" "$diagnostics" ||
    fail "missing clone retry diagnostic"
  assert_eq 2 "$(read_count "${TEST_STATE_DIR}/clone_calls")" "clone retry attempt count"
  assert_eq "$expected_args" "$actual_args" "clone retry arguments"
}

tests=(
  test_git_failure_then_success
  test_repeated_git_failure
  test_pipeline_failure_then_success
  test_empty_discovery
  test_invalid_discovery
  test_annotated_and_version_tag_ordering
  test_clone_rejects_empty_tag
  test_clone_failure_then_success
)

for test_case in "${tests[@]}"; do
  "$test_case"
  echo "PASS: $test_case"
done

echo "PASS: ${#tests[@]} Orion tag-discovery tests"
