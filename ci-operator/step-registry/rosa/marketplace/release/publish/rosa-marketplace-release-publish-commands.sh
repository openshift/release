#!/bin/bash

set +x
set -euo pipefail

readonly SHARED_DIR="${SHARED_DIR:-/tmp}"
readonly MARKETPLACE_ENVIRONMENT="${MARKETPLACE_ENVIRONMENT:-staging}"
readonly MARKETPLACE_DRY_RUN="${MARKETPLACE_DRY_RUN:-true}"
readonly CREDENTIALS_DIR="${MARKETPLACE_AWS_CREDENTIALS_DIR:-/etc/rosa-marketplace-stage}"
readonly AWS_BIN="${AWS_BIN:-aws}"
readonly EXPECTED_ACCOUNT_ID="125666959065"
readonly EXPECTED_USER_ARN="arn:aws:iam::125666959065:user/rosa-marketplace-release-generator-ci"
readonly STAGING_PRODUCT_CODE="5316afb0-9ac2-4c40-8c8d-8fd2a6f56856"

readonly STATE_FILE="${SHARED_DIR}/rosa-marketplace-release-state"
readonly OCP_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-ocp-version"

log() {
  printf '[rosa-marketplace-release-publish] %s\n' "$*"
}

fail() {
  log "ERROR: $*" >&2
  exit 1
}

read_required_value() {
  local path="$1"
  local value

  [[ -s "${path}" ]] || fail "required detector output is missing or empty: ${path}"
  value=$(<"${path}")
  [[ "${value}" != *$'\n'* ]] || fail "detector output must contain one line: ${path}"
  printf '%s' "${value}"
}

run_aws_read() {
  local check_name="$1"
  local error_output
  shift

  if error_output=$("${AWS_BIN}" "$@" 2>&1 >/dev/null); then
    log "${check_name} readable"
    return 0
  fi
  if [[ "${error_output}" =~ \(([A-Za-z][A-Za-z0-9._-]*)\) ]]; then
    fail "${check_name} read check failed (${BASH_REMATCH[1]})"
  fi
  fail "${check_name} read check failed"
}

verify_staging_aws() {
  local field
  local identity
  local account_id
  local principal_arn

  for field in aws_access_key_id aws_secret_access_key aws_account_id; do
    if [[ ! -s "${CREDENTIALS_DIR}/${field}" ]]; then
      log "WARNING: staging AWS credentials are missing; skipping read checks in dry-run"
      return 0
    fi
  done

  [[ "$(<"${CREDENTIALS_DIR}/aws_account_id")" == "${EXPECTED_ACCOUNT_ID}" ]] \
    || fail "mounted staging account ID does not match the expected account"
  command -v "${AWS_BIN}" >/dev/null 2>&1 || fail "AWS CLI is not available"

  unset AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(<"${CREDENTIALS_DIR}/aws_access_key_id")"
  AWS_SECRET_ACCESS_KEY="$(<"${CREDENTIALS_DIR}/aws_secret_access_key")"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  export AWS_EC2_METADATA_DISABLED=true
  export AWS_PAGER=""

  identity=$("${AWS_BIN}" sts get-caller-identity --region us-east-1 \
    --query '[Account,Arn]' --output text 2>/dev/null) \
    || fail "AWS identity check failed"
  read -r account_id principal_arn <<< "${identity}"
  [[ "${account_id}" == "${EXPECTED_ACCOUNT_ID}" ]] || fail "AWS identity is not the staging account"
  [[ "${principal_arn}" == "${EXPECTED_USER_ARN}" ]] || fail "AWS identity is not the release CI user"
  log "Verified account_id=${account_id} principal_arn=${principal_arn}"

  run_aws_read "EC2 DescribeImages" ec2 describe-images --region us-east-1 \
    --owners self --page-size 100 --max-items 1 --output json
  run_aws_read "Marketplace DescribeEntity" marketplace-catalog describe-entity \
    --region us-east-1 --catalog AWSMarketplace --entity-id "${STAGING_PRODUCT_CODE}" \
    --output json
  log "Staging AWS read checks passed"

  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

main() {
  local state
  local ocp_version

  [[ "${MARKETPLACE_DRY_RUN}" == "true" ]] \
    || fail "MARKETPLACE_DRY_RUN must be true; live publication is disabled"

  verify_staging_aws

  state=$(read_required_value "${STATE_FILE}")
  case "${state}" in
    wait:*)
      log "No action: detector state is ${state}"
      return 0
      ;;
    ready)
      ;;
    *)
      fail "unexpected detector state: ${state}"
      ;;
  esac

  ocp_version=$(read_required_value "${OCP_VERSION_FILE}")
  [[ "${ocp_version}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "detector OCP version is invalid"
  [[ "${MARKETPLACE_ENVIRONMENT}" == "staging" ]] \
    || fail "only the staging Marketplace environment is allowed"
  log "Dry-run preview: would release ocp_version=${ocp_version} to ${MARKETPLACE_ENVIRONMENT}; generator not invoked, no AWS writes or publication"
}

main "$@"
