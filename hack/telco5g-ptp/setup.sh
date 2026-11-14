#!/bin/bash
# Phase 1/3: deploy the OCP cluster used by the telco5g PTP tests.
#
# Runs the same command as CI:
#   ci-operator/step-registry/telco5g/ptp-cluster-setup
# In a ci-operator pod the step SSHes to the hypervisor. On the hypervisor the
# wrapper exports HYPERVISOR_LOCAL=true so the identical step commands run
# locally, and the install progress streams in the container log:
#
#   podman logs -f telco5g-ptp-cluster-setup
#
# Usage: ./setup.sh [--version X.Y]
#
#   --version X.Y  release stream to install (default 5.1, passed to kcli as
#                  -P tag=X.Y -P version=nightly)
#
# Environment: T5CI_VERSION (default 5.1), KCLI_PARAM (overrides the -P value
# built from --version), TELCO5G_PTP_DIR, CONTAINER_ENGINE.

# shellcheck source=hack/telco5g-ptp/lib.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --version)
    [[ $# -ge 2 ]] || die "--version needs a value"
    T5CI_VERSION="$2"
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

if [[ "${TELCO5G_PTP_CI_MODE}" == "true" ]]; then
  require_step "${SETUP_STEP}"
  exec bash "${SETUP_STEP}"
fi

require_step "${SETUP_STEP}"
ensure_dirs

# --version wins unless the caller pinned KCLI_PARAM explicitly.
if [[ "${TELCO5G_PTP_KCLI_PARAM_EXPLICIT}" != "true" ]]; then
  KCLI_PARAM="-P tag=${T5CI_VERSION} -P version=nightly"
fi
export T5CI_VERSION KCLI_PARAM HYPERVISOR_LOCAL=true

log "running the cluster-setup step locally (${KCLI_PARAM})"
exec bash "${SETUP_STEP}"
