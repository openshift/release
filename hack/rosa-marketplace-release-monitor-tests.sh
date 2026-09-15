#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly DETECTOR="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-commands.sh"
readonly DETECTOR_REF="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-ref.yaml"
readonly PUBLISHER="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/publish/rosa-marketplace-release-publish-commands.sh"
readonly PUBLISHER_REF="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/publish/rosa-marketplace-release-publish-ref.yaml"
readonly PERIODIC_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/release/openshift-release-main__rosa-marketplace-release.yaml"
readonly SOURCE_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/release/openshift-release-main.yaml"
readonly GENERATED_PERIODICS="${REPO_ROOT}/ci-operator/jobs/openshift/release/openshift-release-main-periodics.yaml"
readonly GENERATED_PRESUBMITS="${REPO_ROOT}/ci-operator/jobs/openshift/release/openshift-release-main-presubmits.yaml"
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

assert_file_contains() {
  local expected="$1"
  local path="$2"

  [[ -f "${path}" ]] || fail "missing file ${path}"
  grep -Fq -- "${expected}" "${path}" \
    || fail "expected ${path} to contain: ${expected}"
}

assert_file_matches() {
  local expected_regex="$1"
  local path="$2"

  [[ -f "${path}" ]] || fail "missing file ${path}"
  grep -Eq -- "${expected_regex}" "${path}" \
    || fail "expected ${path} to match: ${expected_regex}"
}

assert_file_order() {
  local first="$1"
  local second="$2"
  local path="$3"
  local first_line
  local second_line

  first_line=$(awk -v expected="${first}" 'index($0, expected) { print NR; exit }' "${path}")
  second_line=$(awk -v expected="${second}" 'index($0, expected) { print NR; exit }' "${path}")
  [[ -n "${first_line}" && -n "${second_line}" ]] \
    || fail "could not find ordered values in ${path}"
  (( first_line < second_line )) \
    || fail "expected '${first}' before '${second}' in ${path}"
}

run_detector() {
  local output_dir="$1"

  TARGET_OCP_Y_STREAM=5.2 \
  RELEASE_CONTROLLER_API="${TEST_RELEASE_CONTROLLER_API:-https://release-controller.test}" \
  RELEASE_CONTROLLER_RETRIES="${TEST_RELEASE_CONTROLLER_RETRIES:-1}" \
  RELEASE_CONTROLLER_RETRY_DELAY_SECONDS="${TEST_RELEASE_CONTROLLER_RETRY_DELAY_SECONDS:-0}" \
  RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS="${TEST_RELEASE_CONTROLLER_MAX_RETRY_DELAY_SECONDS:-30}" \
  RELEASE_CONTROLLER_MAX_RESPONSE_BYTES="${TEST_RELEASE_CONTROLLER_MAX_RESPONSE_BYTES:-10485760}" \
  RELEASE_PAYLOAD_AUTH_FILE="${TEST_RELEASE_PAYLOAD_AUTH_FILE:-/etc/pull-secret/.dockerconfigjson}" \
  SHARED_DIR="${output_dir}/shared" \
  ARTIFACT_DIR="${output_dir}/artifacts" \
  CURL_BIN="${TEST_ROOT}/mock-curl.sh" \
  OC_BIN="${TEST_OC_BIN:-oc}" \
  SLEEP_BIN="${TEST_SLEEP_BIN:-sleep}" \
  ROSA_MARKETPLACE_INSTALLER_BIN="${TEST_INSTALLER_BIN-${TEST_ROOT}/mock-openshift-install.sh}" \
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
  TEST_MOCK_INSTALLER_SOURCE="${TEST_ROOT}/mock-openshift-install.sh" \
  TEST_OC_ARGS_FILE="${TEST_OC_ARGS_FILE:-}" \
  "${DETECTOR}"
}

test_unknown_stream_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_CONFIG_HTTP_CODE=400 TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" run_detector "${output_dir}"
  assert_file_value "wait:stream-config-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_missing_tags_endpoint_waits() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_HTTP_CODE=404 TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" run_detector "${output_dir}"
  assert_file_value "wait:stream-tags-unavailable" "${output_dir}/shared/rosa-marketplace-release-state"
}

test_wrong_config_stream_name_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_CONFIG_FIXTURE="${FIXTURES}/config-wrong-stream.json" \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
      run_detector "${output_dir}"; then
    fail "mismatched config stream unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "mismatched config stream wrote an actionable detector state"
}

test_unexpected_api_status_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_CONFIG_HTTP_CODE=401 \
    TEST_TAGS_FIXTURE="${FIXTURES}/tags-empty.json" \
      run_detector "${output_dir}"; then
    fail "unexpected release-controller status succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "unexpected release-controller status wrote an actionable detector state"
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

test_rhcos_metadata_is_recorded() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-accepted.json" run_detector "${output_dir}"

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

test_oc_extracts_installer_from_selected_payload() {
  local auth_file
  local output_dir
  output_dir=$(mktemp -d)
  auth_file="${output_dir}/pull-secret/.dockerconfigjson"
  mkdir -p "${output_dir}/pull-secret"
  printf '{}\n' > "${auth_file}"

  TEST_INSTALLER_BIN= \
  TEST_OC_BIN="${TEST_ROOT}/mock-oc.sh" \
  TEST_OC_ARGS_FILE="${output_dir}/oc-args" \
  TEST_RELEASE_PAYLOAD_AUTH_FILE="${auth_file}" \
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" \
    run_detector "${output_dir}"

  assert_file_value "ready" "${output_dir}/shared/rosa-marketplace-release-state"
  assert_file_contains "adm" "${output_dir}/oc-args"
  assert_file_contains "release" "${output_dir}/oc-args"
  assert_file_contains "extract" "${output_dir}/oc-args"
  assert_file_contains "-a" "${output_dir}/oc-args"
  assert_file_contains "${auth_file}" "${output_dir}/oc-args"
  assert_file_contains "--command=openshift-install" "${output_dir}/oc-args"
  assert_file_matches \
    "^--to=${output_dir}/shared/rosa-marketplace-installer\\.[^/]+$" \
    "${output_dir}/oc-args"
  assert_file_contains \
    "registry.ci.openshift.org/ocp/release:ready" \
    "${output_dir}/oc-args"
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

test_detector_step_contract() {
  assert_file_contains "as: rosa-marketplace-release-detect" "${DETECTOR_REF}"
  assert_file_contains "- name: TARGET_OCP_Y_STREAM" "${DETECTOR_REF}"
  assert_file_contains "- name: RELEASE_CONTROLLER_API" "${DETECTOR_REF}"
  assert_file_contains "- name: RELEASE_PAYLOAD_AUTH_FILE" "${DETECTOR_REF}"
  assert_file_contains "name: ci-pull-credentials" "${DETECTOR_REF}"
  assert_file_contains "mount_path: /etc/pull-secret" "${DETECTOR_REF}"
}

test_publisher_step_contract() {
  assert_file_contains "as: rosa-marketplace-release-publish" "${PUBLISHER_REF}"
  assert_file_contains "- name: MARKETPLACE_PUBLISH_ENABLED" "${PUBLISHER_REF}"
  assert_file_contains 'default: "false"' "${PUBLISHER_REF}"
  assert_file_contains "- name: MARKETPLACE_DRY_RUN" "${PUBLISHER_REF}"
  assert_file_contains 'default: "true"' "${PUBLISHER_REF}"
}

test_periodic_config_contract() {
  assert_file_contains "interval: 4h" "${PERIODIC_CONFIG}"
  assert_file_contains 'MARKETPLACE_PUBLISH_ENABLED: "false"' "${PERIODIC_CONFIG}"
  assert_file_contains 'TARGET_OCP_Y_STREAM: "5.2"' "${PERIODIC_CONFIG}"
  assert_file_order \
    "- ref: rosa-marketplace-release-detect" \
    "- ref: rosa-marketplace-release-publish" \
    "${PERIODIC_CONFIG}"
}

test_generated_periodic_is_rehearsable() {
  assert_file_contains \
    "name: periodic-ci-openshift-release-main-rosa-marketplace-release-rosa-marketplace-release-detect" \
    "${GENERATED_PERIODICS}"
  assert_file_contains 'pj-rehearse.openshift.io/can-be-rehearsed: "true"' "${GENERATED_PERIODICS}"
}

test_full_suite_presubmit_contract() {
  assert_file_contains "as: rosa-marketplace-release-monitor-test" "${SOURCE_CONFIG}"
  assert_file_contains \
    "commands: bash hack/rosa-marketplace-release-monitor-tests.sh" \
    "${SOURCE_CONFIG}"
  assert_file_contains \
    "name: pull-ci-openshift-release-main-rosa-marketplace-release-monitor-test" \
    "${GENERATED_PRESUBMITS}"
  assert_file_contains \
    "context: ci/prow/rosa-marketplace-release-monitor-test" \
    "${GENERATED_PRESUBMITS}"
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

test_detector_publisher_handoff() {
  local output_dir
  output_dir=$(mktemp -d)
  TEST_TAGS_FIXTURE="${FIXTURES}/tags-built.json" run_detector "${output_dir}"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_PUBLISH_ENABLED=true \
  MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
  TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
    "${PUBLISHER}"

  assert_file_contains "5.2" "${output_dir}/generator-args"
  assert_file_contains "10.2.20260909-0" "${output_dir}/generator-args"
  assert_file_contains "--dry-run" "${output_dir}/generator-args"
}

test_publisher_rejects_unexpected_state() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'complete\n' > "${output_dir}/shared/rosa-marketplace-release-state"

  if SHARED_DIR="${output_dir}/shared" "${PUBLISHER}"; then
    fail "publisher accepted an unexpected detector state"
  fi
}

test_publisher_requires_detector_outputs() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"

  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_PUBLISH_ENABLED=true \
    MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
    TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
      "${PUBLISHER}"; then
    fail "publisher succeeded without detector output values"
  fi
  [[ ! -e "${output_dir}/generator-args" ]] || fail "publisher invoked generator without detector outputs"
}

test_publisher_validates_safety_settings() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'ready\n' > "${output_dir}/shared/rosa-marketplace-release-state"
  printf '5.2\n' > "${output_dir}/shared/rosa-marketplace-ocp-version"
  printf '10.2.20260909-0\n' > "${output_dir}/shared/rosa-marketplace-rhcos-version"

  if SHARED_DIR="${output_dir}/shared" MARKETPLACE_PUBLISH_ENABLED=yes "${PUBLISHER}"; then
    fail "publisher accepted an invalid publish-enabled value"
  fi
  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_PUBLISH_ENABLED=true \
    MARKETPLACE_DRY_RUN=yes \
      "${PUBLISHER}"; then
    fail "publisher accepted an invalid dry-run value"
  fi
  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_PUBLISH_ENABLED=true \
    MARKETPLACE_RELEASE_TIMEOUT=forever \
      "${PUBLISHER}"; then
    fail "publisher accepted an invalid timeout"
  fi
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

run_tests() {
  local test_name

  for test_name in "$@"; do
    printf 'RUN: %s\n' "${test_name}"
    "${test_name}"
  done
}

run_release_controller_api_tests() {
  run_tests \
    test_unknown_stream_waits \
    test_missing_tags_endpoint_waits \
    test_wrong_config_stream_name_fails \
    test_unexpected_api_status_fails \
    test_invalid_target_fails \
    test_insecure_release_controller_api_fails \
    test_release_controller_credentials_are_not_logged \
    test_oversized_response_fails_before_parsing \
    test_malformed_tags_fail \
    test_wrong_stream_name_fails \
    test_transient_api_failures_retry_then_succeed \
    test_transient_api_failures_exhaust_retries
}

run_payload_selection_tests() {
  run_tests \
    test_empty_tags_waits \
    test_pending_tag_waits \
    test_first_built_payload_is_ready \
    test_accepted_payload_is_eligible \
    test_rejected_payload_is_eligible \
    test_failed_payload_waits \
    test_missing_pullspec_fails
}

run_rhcos_extraction_tests() {
  run_tests \
    test_rhcos_metadata_is_recorded \
    test_missing_rhcos_version_fails \
    test_missing_rhcos_ami_fails \
    test_installer_failure_stops_detection \
    test_oc_extracts_installer_from_selected_payload
}

run_prow_contract_tests() {
  run_tests \
    test_detector_step_contract \
    test_publisher_step_contract \
    test_periodic_config_contract \
    test_generated_periodic_is_rehearsable \
    test_full_suite_presubmit_contract
}

run_publisher_tests() {
  run_tests \
    test_publisher_skips_wait_state \
    test_detector_publisher_handoff \
    test_publisher_rejects_unexpected_state \
    test_publisher_requires_detector_outputs \
    test_publisher_validates_safety_settings \
    test_publisher_ready_but_disabled \
    test_publisher_refuses_production \
    test_publisher_dry_run_arguments \
    test_publisher_non_dry_run_arguments \
    test_generator_failure_propagates
}

run_group() {
  local group="$1"

  case "${group}" in
    release-controller-api)
      run_release_controller_api_tests
      ;;
    payload-selection)
      run_payload_selection_tests
      ;;
    rhcos-extraction)
      run_rhcos_extraction_tests
      ;;
    prow-contract)
      run_prow_contract_tests
      ;;
    publisher)
      run_publisher_tests
      ;;
    all)
      run_release_controller_api_tests
      run_payload_selection_tests
      run_rhcos_extraction_tests
      run_prow_contract_tests
      run_publisher_tests
      ;;
    *)
      fail "unknown test group '${group}'; expected release-controller-api, payload-selection, rhcos-extraction, prow-contract, publisher, or all"
      ;;
  esac
}

main() {
  local group

  if (( $# == 0 )); then
    set -- all
  fi

  for group in "$@"; do
    printf 'GROUP: %s\n' "${group}"
    run_group "${group}"
  done

  printf 'PASS: rosa marketplace release monitor tests\n'
}

main "$@"
