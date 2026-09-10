#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly DETECTOR="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-commands.sh"
readonly PUBLISHER="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/publish/rosa-marketplace-release-publish-commands.sh"
readonly TEST_ROOT="${REPO_ROOT}/hack/rosa-marketplace-release-monitor"
readonly FIXTURES="${TEST_ROOT}/fixtures"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file_value() {
  local expected="$1"
  local path="$2"
  local actual

  [[ -f "${path}" ]] || fail "missing file ${path}"
  actual=$(<"${path}")
  [[ "${actual}" == "${expected}" ]] || fail "expected ${path}=${expected}, got ${actual}"
}

run_detector() {
  local output_dir="$1"

  TARGET_OCP_Y_STREAM=5.2 \
  RELEASE_CONTROLLER_API="${TEST_RELEASE_CONTROLLER_API:-https://release-controller.test}" \
  RELEASE_CONTROLLER_RETRIES="${TEST_RELEASE_CONTROLLER_RETRIES:-1}" \
  RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${TEST_RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-0}" \
  RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${TEST_RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}" \
  RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${TEST_RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}" \
  SHARED_DIR="${output_dir}/shared" \
  ARTIFACT_DIR="${output_dir}/artifacts" \
  CURL_BIN="${TEST_ROOT}/mock-curl.sh" \
  SLEEP_BIN="${TEST_SLEEP_BIN:-sleep}" \
  ROSA_MARKETPLACE_INSTALLER_BIN="${TEST_ROOT}/mock-openshift-install.sh" \
  TEST_CONFIG_FIXTURE="${TEST_CONFIG_FIXTURE:-${FIXTURES}/config.json}" \
  TEST_TAGS_FIXTURE="${TEST_TAGS_FIXTURE}" \
  TEST_CONFIG_HTTP_CODE="${TEST_CONFIG_HTTP_CODE:-200}" \
  TEST_TAGS_HTTP_CODE="${TEST_TAGS_HTTP_CODE:-200}" \
  TEST_CONFIG_TRANSIENT_FAILURES="${TEST_CONFIG_TRANSIENT_FAILURES:-0}" \
  TEST_CONFIG_ATTEMPT_FILE="${TEST_CONFIG_ATTEMPT_FILE:-}" \
  TEST_SLEEP_ARGS_FILE="${TEST_SLEEP_ARGS_FILE:-}" \
  TEST_EXPECTED_MAX_FILESIZE="${TEST_RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}" \
  TEST_COREOS_FIXTURE="${TEST_COREOS_FIXTURE:-${FIXTURES}/coreos-stream.json}" \
  TEST_INSTALLER_EXIT_CODE="${TEST_INSTALLER_EXIT_CODE:-0}" \
  "${DETECTOR}"
}

test_unknown_stream_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_CONFIG_HTTP_CODE=400 TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" run_detector "${output_dir}"
  assert_file_value "wait:stream-config-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_empty_tags_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" run_detector "${output_dir}"
  assert_file_value "wait:built-nightly-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_pending_tag_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-pending.json" run_detector "${output_dir}"
  assert_file_value "wait:built-nightly-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_first_built_payload_is_ready() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" run_detector "${output_dir}"

  assert_file_value "ready" "${output_dir}/shared/rosa-marketplace-release-state"
  assert_file_value "5.2" "${output_dir}/shared/rosa-marketplace-ocp-version"
  assert_file_value "5.2.0-0.nightly-2026-09-09-010101" "${output_dir}/shared/rosa-marketplace-payload-tag"
  assert_file_value "registry.ci.openshift.org/ocp/release:ready" "${output_dir}/shared/rosa-marketplace-payload-pullspec"
  assert_file_value "10.2.20260909-0" "${output_dir}/shared/rosa-marketplace-rhcos-version"
  assert_file_value "ami-0123456789abcdef0" "${output_dir}/shared/rosa-marketplace-rhcos-ami"
}

test_accepted_payload_is_eligible() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-accepted.json" run_detector "${output_dir}"
  assert_file_value "ready" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_rejected_payload_is_eligible() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-rejected.json" run_detector "${output_dir}"
  assert_file_value "ready" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_failed_payload_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-failed.json" run_detector "${output_dir}"
  assert_file_value "wait:built-nightly-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_invalid_target_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TARGET_OCP_Y_STREAM=release-5.2 \
    SHARED_DIR="${output_dir}/shared" \
    ARTIFACT_DIR="${output_dir}/artifacts" \
    CURL_BIN="${TEST_ROOT}/mock-curl.sh" \
    "${DETECTOR}"; then
    fail "invalid target unexpectedly succeeded"
  fi
}

test_insecure_release_controller_api_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TARGET_OCP_Y_STREAM=5.2 \
    RELEASE_CONTROLLER_API=http://release-controller.test \
    SHARED_DIR="${output_dir}/shared" \
    ARTIFACT_DIR="${output_dir}/artifacts" \
    CURL_BIN="${TEST_ROOT}/mock-curl.sh" \
    "${DETECTOR}"; then
    fail "insecure release-controller API unexpectedly succeeded"
  fi
}

test_release_controller_credentials_are_not_logged() {
  local api
  local log_file
  local log_output
  local output_dir
  local secret="do-not-log-this-secret"

  for api in \
    "https://user:${secret}@release-controller.test" \
    "https://release-controller.test?token=${secret}"; do
    output_dir=$(mktemp -d)
    log_file="${output_dir}/detector.log"
    if TEST_RELEASE_CONTROLLER_API="${api}" \
      TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
      run_detector "${output_dir}" >"${log_file}" 2>&1; then
      fail "release-controller API containing credentials unexpectedly succeeded"
    fi
    log_output=$(<"${log_file}")
    [[ "${log_output}" != *"${secret}"* ]] || fail "release-controller credentials were logged"
  done
}

test_oversized_response_fails_before_parsing() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_RELEASE_CONTROLLER_MAX_RESPONSE_BYTES=1 \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
    run_detector "${output_dir}"; then
    fail "oversized release-controller response unexpectedly succeeded"
  fi
  [[ ! -s "${output_dir}/artifacts/rosa-marketplace-release-config.json" ]] \
    || fail "oversized response was retained for parsing"
}

test_malformed_tags_fail() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_TAGS_FIXTURE="${FIXTURES}/tags-malformed.json" run_detector "${output_dir}"; then
    fail "malformed tags response unexpectedly succeeded"
  fi
}

test_wrong_stream_name_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_TAGS_FIXTURE="${FIXTURES}/tags-wrong-stream.json" run_detector "${output_dir}"; then
    fail "mismatched tags stream unexpectedly succeeded"
  fi
}

test_missing_pullspec_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_TAGS_FIXTURE="${FIXTURES}/tags-missing-pullspec.json" run_detector "${output_dir}"; then
    fail "payload without pullSpec unexpectedly succeeded"
  fi
}

test_missing_rhcos_version_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_COREOS_FIXTURE="${FIXTURES}/coreos-stream-missing-version.json" \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" \
      run_detector "${output_dir}"; then
    fail "missing RHCOS version unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "missing RHCOS version wrote an actionable detector state"
}

test_missing_rhcos_ami_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_COREOS_FIXTURE="${FIXTURES}/coreos-stream-missing-ami.json" \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" \
      run_detector "${output_dir}"; then
    fail "missing regional RHCOS AMI unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "missing regional RHCOS AMI wrote an actionable detector state"
}

test_installer_failure_stops_detection() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_INSTALLER_EXIT_CODE=41 \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" \
      run_detector "${output_dir}"; then
    fail "installer failure unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "installer failure wrote an actionable detector state"
}

test_transient_api_failures_retry_then_succeed() {
  local output_dir
  output_dir=$(mktemp -d)

  TEST_CONFIG_ATTEMPT_FILE="${output_dir}/config-attempts" \
  TEST_CONFIG_TRANSIENT_FAILURES=2 \
  TEST_RELEASE_CONTROLLER_RETRIES=3 \
  TEST_RELEASE_CONTROLLER_RETRY_DELAY_SECONDS=2 \
  TEST_RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS=8 \
  TEST_SLEEP_BIN="${TEST_ROOT}/mock-sleep.sh" \
  TEST_SLEEP_ARGS_FILE="${output_dir}/sleep-args" \
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
    run_detector "${output_dir}"

  assert_file_value "3" "${output_dir}/config-attempts"
  assert_file_value $'2\n4' "${output_dir}/sleep-args"
  assert_file_value "wait:built-nightly-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_transient_api_failures_exhaust_retries() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_CONFIG_ATTEMPT_FILE="${output_dir}/config-attempts" \
    TEST_CONFIG_TRANSIENT_FAILURES=3 \
    TEST_RELEASE_CONTROLLER_RETRIES=3 \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
      run_detector "${output_dir}"; then
    fail "persistent API failures unexpectedly succeeded"
  fi

  assert_file_value "3" "${output_dir}/config-attempts"
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "persistent API failure wrote an actionable detector state"
}

test_publisher_skips_wait_state() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'wait:stream-config-unavailable\n' > "${output_dir}/shared/rosa-marketplace-release-state"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_GENERATOR_BIN="${output_dir}/generator-is-intentionally-absent" \
  "${PUBLISHER}"

  [[ ! -e "${output_dir}/generator-args" ]] || fail "publisher invoked generator for a wait state"
}

test_publisher_dry_run_arguments() {
  local output_dir
  local expected_args
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"
  printf '10.2.20260909-0\n' > "${output_dir}/shared/rosa-marketplace-rhcos-version"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_PUBLISH_ENABLED=true \
  MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
  TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
  "${PUBLISHER}"

  expected_args=$'release\n--environment\nstaging\n--ocp-version\n5.2\n--rhcos-version\n10.2.20260909-0\n--aws-profile\nmarketplacestaging\n--copy-if-duplicate=false\n--timeout\n2h\n--dry-run'
  assert_file_value "${expected_args}" "${output_dir}/generator-args"
}

test_publisher_ready_but_disabled() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_GENERATOR_BIN="${output_dir}/generator-is-intentionally-absent" \
  "${PUBLISHER}"

  [[ ! -e "${output_dir}/generator-args" ]] || fail "disabled publisher invoked generator"
}

test_publisher_refuses_production() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"

  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_ENVIRONMENT=production \
    MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
    TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
      "${PUBLISHER}"; then
    fail "publisher unexpectedly permitted production"
  fi
  [[ ! -e "${output_dir}/generator-args" ]] || fail "production refusal invoked generator"
}

test_publisher_non_dry_run_arguments() {
  local output_dir
  local expected_args
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"
  printf '10.2.20260909-0\n' > "${output_dir}/shared/rosa-marketplace-rhcos-version"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_PUBLISH_ENABLED=true \
  MARKETPLACE_DRY_RUN=false \
  MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
  TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
    "${PUBLISHER}"

  expected_args=$'release\n--environment\nstaging\n--ocp-version\n5.2\n--rhcos-version\n10.2.20260909-0\n--aws-profile\nmarketplacestaging\n--copy-if-duplicate=false\n--timeout\n2h'
  assert_file_value "${expected_args}" "${output_dir}/generator-args"
}

test_generator_failure_propagates() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"
  printf '10.2.20260909-0\n' > "${output_dir}/shared/rosa-marketplace-rhcos-version"

  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_PUBLISH_ENABLED=true \
    MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
    TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
    TEST_GENERATOR_EXIT_CODE=42 \
      "${PUBLISHER}"; then
    fail "generator failure did not fail publisher"
  fi
  [[ -s "${output_dir}/generator-args" ]] || fail "failing generator was not invoked"
}

test_unknown_stream_waits
test_empty_tags_waits
test_pending_tag_waits
test_first_built_payload_is_ready
test_accepted_payload_is_eligible
test_rejected_payload_is_eligible
test_failed_payload_waits
test_invalid_target_fails
test_insecure_release_controller_api_fails
test_release_controller_credentials_are_not_logged
test_oversized_response_fails_before_parsing
test_malformed_tags_fail
test_wrong_stream_name_fails
test_missing_pullspec_fails
test_missing_rhcos_version_fails
test_missing_rhcos_ami_fails
test_installer_failure_stops_detection
test_transient_api_failures_retry_then_succeed
test_transient_api_failures_exhaust_retries
test_publisher_skips_wait_state
test_publisher_ready_but_disabled
test_publisher_refuses_production
test_publisher_dry_run_arguments
test_publisher_non_dry_run_arguments
test_generator_failure_propagates

printf 'PASS: rosa marketplace release monitor tests\n'
