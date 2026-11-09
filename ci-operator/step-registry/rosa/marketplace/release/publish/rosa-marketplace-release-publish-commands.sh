#!/bin/bash

set -euo pipefail

readonly SHARED_DIR="${SHARED_DIR:-/tmp}"
readonly MARKETPLACE_ENVIRONMENT="${MARKETPLACE_ENVIRONMENT:-staging}"
readonly MARKETPLACE_DRY_RUN="${MARKETPLACE_DRY_RUN:-true}"

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

main() {
  local state
  local ocp_version

  [[ "${MARKETPLACE_DRY_RUN}" == "true" ]] \
    || fail "MARKETPLACE_DRY_RUN must be true; live publication is disabled"

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
  log "Dry-run preview: would release ocp_version=${ocp_version} to ${MARKETPLACE_ENVIRONMENT}; generator not invoked, no AWS access or publication"
}

main "$@"
