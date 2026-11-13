#!/bin/bash
# Phase 3/3: collect must-gather, audit logs, camgi and PTP test results from
# the cluster and the runner directory.
#
# Runs the same command as CI:
#   ci-operator/step-registry/telco5g/ptp/gather
# In a ci-operator pod the step SSHes to the hypervisor. On the hypervisor the
# wrapper exports HYPERVISOR_LOCAL=true so the identical step commands run
# locally and the artifacts stay in ${TELCO5G_PTP_DIR}/artifacts.
#
# Usage: ./gather.sh
#
# Environment: TELCO5G_PTP_DIR, MUST_GATHER_TIMEOUT, CONTAINER_ENGINE.

# shellcheck source=hack/telco5g-ptp/lib.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1 (try --help)" ;;
  esac
done

if [[ "${TELCO5G_PTP_CI_MODE}" == "true" ]]; then
  require_step "${GATHER_STEP}"
  exec bash "${GATHER_STEP}"
fi

require_step "${GATHER_STEP}"
ensure_dirs
[[ -f "${SHARED_DIR}/kubeconfig" || -f "${HOME}/runner/shared/kubeconfig" ]] \
  || die "no kubeconfig found; run setup.sh (and tests.sh) first"
export HYPERVISOR_LOCAL=true

log "running the gather step locally"
exec bash "${GATHER_STEP}"
