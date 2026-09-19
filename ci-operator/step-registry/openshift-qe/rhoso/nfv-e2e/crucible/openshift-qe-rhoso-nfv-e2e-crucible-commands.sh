#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${SHARED_DIR:?SHARED_DIR must be set}"
: "${BUILD_ID:?BUILD_ID must be set}"
: "${SCENARIO:?SCENARIO must be set}"
: "${TIMEOUT_CRUCIBLE:?TIMEOUT_CRUCIBLE must be set}"
[[ "${TIMEOUT_CRUCIBLE}" =~ ^[1-9][0-9]*$ ]] ||
  { echo 'TIMEOUT_CRUCIBLE must be a positive decimal integer' >&2; exit 1; }
crucible_step_seconds=$((8 * 60 * 60))
crucible_cleanup_allowance=900
crucible_recovery_allowance=240
crucible_evidence_allowance=60
crucible_step_margin=300
crucible_timeout_max=$((crucible_step_seconds - crucible_cleanup_allowance -
  crucible_recovery_allowance - crucible_evidence_allowance - crucible_step_margin))
(( TIMEOUT_CRUCIBLE <= crucible_timeout_max )) ||
  { echo "TIMEOUT_CRUCIBLE must be <= ${crucible_timeout_max} for the 8-hour step budget" >&2; exit 1; }
: "${EDPM_HOST:?EDPM_HOST must be set}"
: "${FRAME_SIZES:?FRAME_SIZES must be set}"

# shellcheck source=/dev/null
source "${SHARED_DIR}/openshift-qe-rhoso-nfv-e2e-lifecycle.sh"
export LIFECYCLE_CONTROLLER_USER=nfvcpt
export LIFECYCLE_STATE_ROOT=/var/lib/nfv-e2e/lifecycle
export LIFECYCLE_LAB_ENV=/home/zuul/nfv-e2e/lab-init.env

signal_received=false
cancel_failed=false
signal_file="${SHARED_DIR}/.nfv-e2e-lifecycle-signal"
rm -f "${signal_file}"
export LIFECYCLE_SIGNAL_FILE="${signal_file}"
on_signal() {
  signal_received=true
  : >"${signal_file}"
  lifecycle_cancel prow_signal >/dev/null 2>&1 || cancel_failed=true
}
trap on_signal TERM INT HUP
export LIFECYCLE_WAIT_TIMEOUT_SECONDS=$((TIMEOUT_CRUCIBLE + crucible_cleanup_allowance +
  crucible_recovery_allowance + crucible_evidence_allowance))

lifecycle_start \
  "${BUILD_ID}" \
  crucible \
  /home/zuul/netperf-rhoso18-nfv-e2e-validation \
  make e2e-crucible \
  "SCENARIO=${SCENARIO}" \
  LAB_ENV=/home/zuul/nfv-e2e/lab-init.env \
  E2E_EXTRA="--timeout-crucible ${TIMEOUT_CRUCIBLE} --edpm-host ${EDPM_HOST} --frame-sizes ${FRAME_SIZES}" \
  >/dev/null
if [[ "$signal_received" == true ]]; then
  lifecycle_cancel prow_signal >/dev/null 2>&1 || cancel_failed=true
fi

wait_status=0
lifecycle_wait &
wait_pid=$!
wait "$wait_pid" || wait_status=$?
if [[ "$signal_received" == true ]]; then
  wait "$wait_pid" || wait_status=$?
fi
if [[ "$signal_received" == true || "$cancel_failed" == true ]]; then
  exit 1
fi
exit "$wait_status"
