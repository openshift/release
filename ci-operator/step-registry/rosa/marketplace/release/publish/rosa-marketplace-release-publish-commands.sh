#!/bin/bash

set -euo pipefail

readonly SHARED_DIR="${SHARED_DIR:-/tmp}"
readonly MARKETPLACE_ENVIRONMENT="${MARKETPLACE_ENVIRONMENT:-staging}"
readonly MARKETPLACE_AWS_PROFILE="${MARKETPLACE_AWS_PROFILE:-marketplacestaging}"
readonly MARKETPLACE_PUBLISH_ENABLED="${MARKETPLACE_PUBLISH_ENABLED:-false}"
readonly MARKETPLACE_DRY_RUN="${MARKETPLACE_DRY_RUN:-true}"
readonly MARKETPLACE_RELEASE_TIMEOUT="${MARKETPLACE_RELEASE_TIMEOUT:-2h}"
readonly MARKETPLACE_GENERATOR_BIN="${MARKETPLACE_GENERATOR_BIN:-marketplace-release-generator}"

readonly STATE_FILE="${SHARED_DIR}/rosa-marketplace-release-state"
readonly OCP_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-ocp-version"
readonly RHCOS_VERSION_FILE="${SHARED_DIR}/rosa-marketplace-rhcos-version"

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

main() {
  local state
  local ocp_version
  local rhcos_version
  local -a args

  command -v "${MARKETPLACE_GENERATOR_BIN}" >/dev/null 2>&1 \
    || fail "marketplace generator not found: ${MARKETPLACE_GENERATOR_BIN}"

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

  [[ "${MARKETPLACE_ENVIRONMENT}" == "staging" ]] \
    || fail "only the staging Marketplace environment is allowed"
  [[ "${MARKETPLACE_PUBLISH_ENABLED}" == "true" || "${MARKETPLACE_PUBLISH_ENABLED}" == "false" ]] \
    || fail "MARKETPLACE_PUBLISH_ENABLED must be true or false"
  if [[ "${MARKETPLACE_PUBLISH_ENABLED}" == "false" ]]; then
    log "No action: publishing is disabled for ocp_version=$(read_required_value "${OCP_VERSION_FILE}")"
    return 0
  fi

  [[ "${MARKETPLACE_DRY_RUN}" == "true" || "${MARKETPLACE_DRY_RUN}" == "false" ]] \
    || fail "MARKETPLACE_DRY_RUN must be true or false"
  [[ -n "${MARKETPLACE_AWS_PROFILE}" ]] || fail "MARKETPLACE_AWS_PROFILE is required"
  [[ "${MARKETPLACE_RELEASE_TIMEOUT}" =~ ^[1-9][0-9]*(s|m|h)$ ]] \
    || fail "MARKETPLACE_RELEASE_TIMEOUT must be a positive duration using s, m, or h"

  ocp_version=$(read_required_value "${OCP_VERSION_FILE}")
  rhcos_version=$(read_required_value "${RHCOS_VERSION_FILE}")
  [[ "${ocp_version}" =~ ^[0-9]+\.[0-9]+$ ]] || fail "detector OCP version is invalid"
  [[ "${rhcos_version}" =~ ^[A-Za-z0-9._-]+$ ]] || fail "detector RHCOS version is invalid"

  args=(
    release
    --environment "${MARKETPLACE_ENVIRONMENT}"
    --ocp-version "${ocp_version}"
    --rhcos-version "${rhcos_version}"
    --aws-profile "${MARKETPLACE_AWS_PROFILE}"
    --copy-if-duplicate=false
    --timeout "${MARKETPLACE_RELEASE_TIMEOUT}"
  )

  if [[ "${MARKETPLACE_DRY_RUN}" == "true" ]]; then
    args+=(--dry-run)
  fi

  log "Invoking generator for ocp_version=${ocp_version} rhcos_version=${rhcos_version} environment=${MARKETPLACE_ENVIRONMENT} dry_run=${MARKETPLACE_DRY_RUN}"
  "${MARKETPLACE_GENERATOR_BIN}" "${args[@]}"
}

main "$@"
