#!/usr/bin/env bash

set -o nounset
set -o pipefail

export KUBECONFIG

CSR_TIMEOUT_SECONDS="${CSR_TIMEOUT_SECONDS:-600}"
CSR_POLL_SECONDS="${CSR_POLL_SECONDS:-15}"
OC_REQUEST_TIMEOUT_SECONDS="${OC_REQUEST_TIMEOUT_SECONDS:-30}"

POLL_SUCCESS=0
POLL_RETRY=1
POLL_FAILURE=2
# Allow late CSR requests to appear after an initially empty list.
EMPTY_POLL_LIMIT=4

declare -A tracked_csrs=()
pending_csrs=""

# Write a consistent message to the CI log.
log() {
  printf '[approve-csrs] %s\n' "$*"
}

# Validate a positive integer configuration value.
validate_positive_integer() {
  local name="$1"
  local value="$2"

  if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
    log "${name} must be a positive integer: ${value}"
    return 1
  fi
}

if ! validate_positive_integer "CSR_TIMEOUT_SECONDS" "${CSR_TIMEOUT_SECONDS}" ||
  ! validate_positive_integer "CSR_POLL_SECONDS" "${CSR_POLL_SECONDS}" ||
  ! validate_positive_integer "OC_REQUEST_TIMEOUT_SECONDS" "${OC_REQUEST_TIMEOUT_SECONDS}"; then
  exit 1
fi

# Return the seconds remaining before the polling deadline.
seconds_until_deadline() {
  local now

  now="$(date +%s)"
  printf '%s\n' "$((deadline - now))"
}

# Return an API request timeout bounded by the polling deadline.
get_request_timeout() {
  local remaining

  remaining="$(seconds_until_deadline)"
  if (( remaining <= 0 )); then
    return 1
  fi

  if (( remaining < OC_REQUEST_TIMEOUT_SECONDS )); then
    printf '%ss\n' "${remaining}"
  else
    printf '%ss\n' "${OC_REQUEST_TIMEOUT_SECONDS}"
  fi
}

# List CSR states and collect pending CSRs for this poll.
list_csr_states() {
  local output
  local request_timeout
  local csr
  local conditions

  pending_csrs=""

  if ! request_timeout="$(get_request_timeout)"; then
    return 1
  fi

  if ! output="$(oc --request-timeout="${request_timeout}" get csr \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}={.status}{" "}{end}{"\n"}{end}' \
    2>/dev/null)"; then
    log "Unable to list CSRs"
    return 1
  fi

  # A CSR with no conditions is pending. Track it before approval so a later
  # denial or failure cannot be mistaken for a successful approval.
  while IFS=$'\t' read -r csr conditions; do
    [[ -z "${csr}" ]] && continue

    if [[ "${conditions}" == *"Denied=True"* ||
      "${conditions}" == *"Failed=True"* ]]; then
      if [[ -n "${tracked_csrs["${csr}"]+present}" ]]; then
        log "CSR ${csr} was denied or failed"
        printf '%s\n' "${conditions}"
        return "${POLL_FAILURE}"
      fi
      log "Ignoring untracked denied or failed CSR ${csr}"
      continue
    fi

    if [[ -z "${conditions}" ]]; then
      tracked_csrs["${csr}"]=1
      pending_csrs+="${csr}"$'\n'
    fi
  done <<< "${output}"

  return "${POLL_SUCCESS}"
}

# Approve pending CSRs and report whether any approval should be retried.
approve_pending_csrs() {
  local pending="$1"
  local csr
  local approval_failed=false
  local request_timeout

  while IFS= read -r csr; do
    [[ -z "${csr}" ]] && continue

    tracked_csrs["${csr}"]=1
    log "Approving CSR: ${csr}"
    if ! request_timeout="$(get_request_timeout)"; then
      log "Approval deadline reached for ${csr}"
      approval_failed=true
      continue
    fi

    if ! oc --request-timeout="${request_timeout}" adm certificate approve "${csr}" \
      >/dev/null 2>/dev/null; then
      log "Approval failed for ${csr}; it will be retried"
      approval_failed=true
    fi
  done <<< "${pending}"

  if [[ "${approval_failed}" == true ]]; then
    return "${POLL_RETRY}"
  fi

  return "${POLL_SUCCESS}"
}

# Verify tracked CSRs are approved and have issued certificates.
check_tracked_csrs() {
  local csr
  local conditions
  local certificate
  local waiting=false
  local request_timeout

  for csr in "${!tracked_csrs[@]}"; do
    if ! request_timeout="$(get_request_timeout)"; then
      waiting=true
      continue
    fi

    if ! conditions="$(oc --request-timeout="${request_timeout}" get csr "${csr}" \
      -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' \
      2>/dev/null)"; then
      log "Unable to inspect conditions for ${csr}"
      waiting=true
      continue
    fi

    if [[ "${conditions}" == *"Denied=True"* ||
      "${conditions}" == *"Failed=True"* ]]; then
      log "CSR ${csr} was denied or failed"
      printf '%s\n' "${conditions}"
      return "${POLL_FAILURE}"
    fi

    if [[ "${conditions}" != *"Approved=True"* ]]; then
      waiting=true
      continue
    fi

    if ! request_timeout="$(get_request_timeout)"; then
      waiting=true
      continue
    fi

    if ! certificate="$(oc --request-timeout="${request_timeout}" get csr "${csr}" \
      -o jsonpath='{.status.certificate}' 2>/dev/null)"; then
      log "Unable to inspect certificate for ${csr}"
      waiting=true
      continue
    fi

    if [[ -z "${certificate}" ]]; then
      log "CSR ${csr} is approved but not issued yet"
      waiting=true
    fi
  done

  if [[ "${waiting}" == true ]]; then
    return "${POLL_RETRY}"
  fi

  return "${POLL_SUCCESS}"
}

# Sleep for one poll interval without crossing the deadline.
sleep_until_deadline() {
  local remaining
  local sleep_seconds

  remaining="$(seconds_until_deadline)"
  if (( remaining <= 0 )); then
    return 1
  fi

  sleep_seconds="${CSR_POLL_SECONDS}"
  if (( sleep_seconds > remaining )); then
    sleep_seconds="${remaining}"
  fi

  sleep "${sleep_seconds}"
}

# Run one poll in observe, approve, and verify order.
run_poll() {
  local status
  local approval_failed=false

  list_csr_states
  status=$?
  if (( status != POLL_SUCCESS )); then
    return "${status}"
  fi

  if [[ -n "${pending_csrs}" ]]; then
    if ! approve_pending_csrs "${pending_csrs}"; then
      approval_failed=true
    fi
  fi

  check_tracked_csrs
  status=$?
  if (( status == POLL_FAILURE )); then
    return "${POLL_FAILURE}"
  fi

  if [[ -z "${pending_csrs}" &&
    "${approval_failed}" == false &&
    "${status}" -eq "${POLL_SUCCESS}" ]]; then
    return "${POLL_SUCCESS}"
  fi

  return "${POLL_RETRY}"
}

log "Checking and approving Pending CSRs"
start_time="$(date +%s)"
deadline=$((start_time + CSR_TIMEOUT_SECONDS))
empty_polls=0

while true; do
  if (( $(date +%s) >= deadline )); then
    break
  fi

  poll_status=0
  run_poll || poll_status=$?
  case "${poll_status}" in
  "${POLL_SUCCESS}")
    if [[ -z "${pending_csrs}" &&
      "${#tracked_csrs[@]}" -eq 0 &&
      "${empty_polls}" -lt "${EMPTY_POLL_LIMIT}" ]]; then
      empty_polls=$((empty_polls + 1))
      log "No CSRs observed; continuing to poll (${empty_polls}/${EMPTY_POLL_LIMIT})"
    else
      log "No pending CSRs; all tracked CSRs are issued"
      log "Completed check and all CSRs have been approved"
      exit 0
    fi
    ;;
  "${POLL_FAILURE}")
    exit 1
    ;;
  "${POLL_RETRY}")
    empty_polls=0
    ;;
  *)
    log "Unexpected poll status: ${poll_status}"
    exit 1
    ;;
  esac

  if ! sleep_until_deadline; then
    break
  fi
done

log "Timed out after ${CSR_TIMEOUT_SECONDS} seconds"
exit 1
