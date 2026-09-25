#!/bin/bash

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly REPO_ROOT
readonly DETECTOR="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-commands.sh"
readonly DETECTOR_REF="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/detect/rosa-marketplace-release-detect-ref.yaml"
readonly PUBLISHER="${REPO_ROOT}/ci-operator/step-registry/rosa/marketplace/release/publish/rosa-marketplace-release-publish-commands.sh"
readonly NIGHTLY_CONFIG="${REPO_ROOT}/ci-operator/config/openshift/release/openshift-release-main__nightly-5.1.yaml"
readonly RELEASE_CONFIG="${REPO_ROOT}/core-services/release-controller/_releases/release-ocp-5.1.json"
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
  local auth_file="${output_dir}/pull-secret"

  mkdir -p "${output_dir}/shared" "${output_dir}/artifacts"
  printf '{}\n' > "${auth_file}"

  RELEASE_IMAGE_LATEST="${TEST_RELEASE_IMAGE_LATEST:-registry.ci.openshift.org/ocp/release@sha256:0123456789abcdef}" \
  RELEASE_PAYLOAD_AUTH_FILE="${auth_file}" \
  SHARED_DIR="${output_dir}/shared" \
  ARTIFACT_DIR="${output_dir}/artifacts" \
  OC_BIN="${TEST_ROOT}/mock-oc.sh" \
  ROSA_MARKETPLACE_INSTALLER_BIN="${TEST_ROOT}/mock-openshift-install.sh" \
  TEST_RELEASE_INFO_FIXTURE="${TEST_RELEASE_INFO_FIXTURE:-${FIXTURES}/release-info.json}" \
  TEST_OC_INFO_EXIT_CODE="${TEST_OC_INFO_EXIT_CODE:-0}" \
  TEST_COREOS_FIXTURE="${TEST_COREOS_FIXTURE:-${FIXTURES}/coreos-stream.json}" \
  TEST_INSTALLER_EXIT_CODE="${TEST_INSTALLER_EXIT_CODE:-0}" \
  "${DETECTOR}"
}

test_payload_drives_detector() {
  local output_dir
  output_dir=$(mktemp -d)

  run_detector "${output_dir}"

  assert_file_value "ready" "${output_dir}/shared/rosa-marketplace-release-state"
  assert_file_value "5.1" "${output_dir}/shared/rosa-marketplace-ocp-version"
  assert_file_value "5.1.0-0.nightly-2026-09-09-010101" "${output_dir}/shared/rosa-marketplace-payload-tag"
  assert_file_value "registry.ci.openshift.org/ocp/release@sha256:0123456789abcdef" "${output_dir}/shared/rosa-marketplace-payload-pullspec"
  assert_file_value "10.2.20260909-0" "${output_dir}/shared/rosa-marketplace-rhcos-version"
  assert_file_value "ami-0123456789abcdef0" "${output_dir}/shared/rosa-marketplace-rhcos-ami"
}

test_missing_payload_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if RELEASE_IMAGE_LATEST= \
    RELEASE_PAYLOAD_AUTH_FILE="${FIXTURES}/release-info.json" \
    SHARED_DIR="${output_dir}/shared" \
    ARTIFACT_DIR="${output_dir}/artifacts" \
    OC_BIN="${TEST_ROOT}/mock-oc.sh" \
      "${DETECTOR}"; then
    fail "missing release payload unexpectedly succeeded"
  fi
}

test_payload_with_whitespace_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_RELEASE_IMAGE_LATEST='registry.invalid/release:tag with-space' run_detector "${output_dir}"; then
    fail "release payload containing whitespace unexpectedly succeeded"
  fi
}

test_missing_payload_version_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_RELEASE_INFO_FIXTURE="${FIXTURES}/release-info-missing-version.json" run_detector "${output_dir}"; then
    fail "release info without a version unexpectedly succeeded"
  fi
}

test_invalid_payload_version_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_RELEASE_INFO_FIXTURE="${FIXTURES}/release-info-invalid-version.json" run_detector "${output_dir}"; then
    fail "invalid release version unexpectedly succeeded"
  fi
}

test_malformed_release_info_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_RELEASE_INFO_FIXTURE="${FIXTURES}/release-info-malformed.json" run_detector "${output_dir}"; then
    fail "malformed release info unexpectedly succeeded"
  fi
}

test_release_info_failure_stops_detection() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_OC_INFO_EXIT_CODE=41 run_detector "${output_dir}"; then
    fail "oc release info failure unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "oc release info failure wrote an actionable state"
}

test_missing_rhcos_version_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_COREOS_FIXTURE="${FIXTURES}/coreos-stream-missing-version.json" run_detector "${output_dir}"; then
    fail "missing RHCOS version unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "missing RHCOS version wrote an actionable state"
}

test_missing_rhcos_ami_fails() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_COREOS_FIXTURE="${FIXTURES}/coreos-stream-missing-ami.json" run_detector "${output_dir}"; then
    fail "missing regional RHCOS AMI unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "missing regional RHCOS AMI wrote an actionable state"
}

test_installer_failure_stops_detection() {
  local output_dir
  output_dir=$(mktemp -d)

  if TEST_INSTALLER_EXIT_CODE=42 run_detector "${output_dir}"; then
    fail "installer failure unexpectedly succeeded"
  fi
  [[ ! -e "${output_dir}/shared/rosa-marketplace-release-state" ]] \
    || fail "installer failure wrote an actionable state"
}

write_ready_outputs() {
  local shared_dir="$1"

  mkdir -p "${shared_dir}"
  printf 'ready\n' > "${shared_dir}/rosa-marketplace-release-state"
  printf '5.1\n' > "${shared_dir}/rosa-marketplace-ocp-version"
  printf '10.2.20260909-0\n' > "${shared_dir}/rosa-marketplace-rhcos-version"
}

test_publisher_ready_but_disabled() {
  local output_dir
  output_dir=$(mktemp -d)
  write_ready_outputs "${output_dir}/shared"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_GENERATOR_BIN="${output_dir}/generator-is-intentionally-absent" \
  "${PUBLISHER}"

  [[ ! -e "${output_dir}/generator-args" ]] || fail "disabled publisher invoked generator"
}

test_publisher_rejects_non_ready_state() {
  local output_dir
  output_dir=$(mktemp -d)
  mkdir -p "${output_dir}/shared"
  printf 'wait:built-nightly-unavailable\n' > "${output_dir}/shared/rosa-marketplace-release-state"

  if SHARED_DIR="${output_dir}/shared" "${PUBLISHER}"; then
    fail "publisher accepted a legacy wait state"
  fi
}

test_publisher_refuses_production() {
  local output_dir
  output_dir=$(mktemp -d)
  write_ready_outputs "${output_dir}/shared"

  if SHARED_DIR="${output_dir}/shared" \
    MARKETPLACE_ENVIRONMENT=production \
      "${PUBLISHER}"; then
    fail "publisher unexpectedly permitted production"
  fi
}

test_publisher_dry_run_arguments() {
  local output_dir
  local expected_args
  output_dir=$(mktemp -d)
  write_ready_outputs "${output_dir}/shared"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_PUBLISH_ENABLED=true \
  MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
  TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
  "${PUBLISHER}"

  expected_args=$'release\n--environment\nstaging\n--ocp-version\n5.1\n--rhcos-version\n10.2.20260909-0\n--aws-profile\nmarketplacestaging\n--copy-if-duplicate=false\n--skip-if-version-exists\n--timeout\n2h\n--dry-run'
  assert_file_value "${expected_args}" "${output_dir}/generator-args"
}

test_publisher_non_dry_run_arguments() {
  local output_dir
  local expected_args
  output_dir=$(mktemp -d)
  write_ready_outputs "${output_dir}/shared"

  SHARED_DIR="${output_dir}/shared" \
  MARKETPLACE_PUBLISH_ENABLED=true \
  MARKETPLACE_DRY_RUN=false \
  MARKETPLACE_GENERATOR_BIN="${TEST_ROOT}/mock-marketplace-release-generator.sh" \
  TEST_GENERATOR_ARGS_FILE="${output_dir}/generator-args" \
  "${PUBLISHER}"

  expected_args=$'release\n--environment\nstaging\n--ocp-version\n5.1\n--rhcos-version\n10.2.20260909-0\n--aws-profile\nmarketplacestaging\n--copy-if-duplicate=false\n--skip-if-version-exists\n--timeout\n2h'
  assert_file_value "${expected_args}" "${output_dir}/generator-args"
}

test_generator_failure_propagates() {
  local output_dir
  output_dir=$(mktemp -d)
  write_ready_outputs "${output_dir}/shared"

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

test_ci_contract_is_payload_driven() {
  [[ ! -e "${REPO_ROOT}/ci-operator/config/openshift/release/openshift-release-main__rosa-marketplace-release.yaml" ]] \
    || fail "fixed-stream monitor configuration still exists"
  grep -q -- '- as: rosa-marketplace-release' "${NIGHTLY_CONFIG}" \
    || fail "nightly configuration does not define rosa-marketplace-release"
  ! grep -q 'TARGET_OCP_Y_STREAM' "${NIGHTLY_CONFIG}" \
    || fail "nightly configuration still fixes an OCP y-stream"
  grep -q 'bundle: ci-pull-credentials' "${DETECTOR_REF}" \
    || fail "detector does not mount the ci-pull-credentials bundle"
  ! grep -q 'name: ci-pull-credentials' "${DETECTOR_REF}" \
    || fail "detector uses an invalid named credential reference"

  "${PYTHON_BIN:-python3}" - "${RELEASE_CONFIG}" <<'PYTHON'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as source:
    config = json.load(source)

job = config["verify"]["rosa-marketplace-release"]
expected = "periodic-ci-openshift-release-main-nightly-5.1-rosa-marketplace-release"
if job.get("optional") is not True or job.get("prowJob", {}).get("name") != expected:
    raise SystemExit("release-controller informing job contract is invalid")
PYTHON
}

test_payload_drives_detector
test_missing_payload_fails
test_payload_with_whitespace_fails
test_missing_payload_version_fails
test_invalid_payload_version_fails
test_malformed_release_info_fails
test_release_info_failure_stops_detection
test_missing_rhcos_version_fails
test_missing_rhcos_ami_fails
test_installer_failure_stops_detection
test_publisher_ready_but_disabled
test_publisher_rejects_non_ready_state
test_publisher_refuses_production
test_publisher_dry_run_arguments
test_publisher_non_dry_run_arguments
test_generator_failure_propagates
test_ci_contract_is_payload_driven

printf 'PASS: rosa marketplace release monitor tests\n'
