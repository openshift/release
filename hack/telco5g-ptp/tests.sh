#!/bin/bash
# Phase 2/3: run the telco5g PTP conformance suites against the installed
# cluster.
#
# Runs the same command as CI:
#   ci-operator/step-registry/telco5g/ptp/tests
# In a ci-operator pod the step SSHes to the hypervisor. On the hypervisor the
# wrapper exports HYPERVISOR_LOCAL=true so the identical step commands run
# locally (kubeconfig and ci.env come from setup.sh in ${TELCO5G_PTP_DIR}).
#
# Usage: ./tests.sh [--version X.Y] [--upstream] [--modes M1,M2]
#
#   --version X.Y  release under test (default 5.1, exported as T5CI_VERSION)
#   --upstream     build and deploy ptp-operator/linuxptp-daemon from upstream main
#   --modes M1,M2  comma-separated PTP test modes (default: all for the release)
#
# Environment: T5CI_VERSION, T5CI_DEPLOY_UPSTREAM, L2_DISCOVERY_IMAGE,
# TEST_REPO, TEST_BRANCH, PTP_REPO, PTP_UNDER_TEST_BRANCH, SKIP_INTERFACES,
# TELCO5G_PTP_DIR, CONTAINER_ENGINE.

# shellcheck source=hack/telco5g-ptp/lib.sh
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

T5CI_DEPLOY_UPSTREAM="${T5CI_DEPLOY_UPSTREAM:-false}"
while [[ $# -gt 0 ]]; do
  case "$1" in
  --version)
    [[ $# -ge 2 ]] || die "--version needs a value"
    T5CI_VERSION="$2"
    shift
    ;;
  --upstream) T5CI_DEPLOY_UPSTREAM=true ;;
  --modes)
    [[ $# -ge 2 ]] || die "--modes needs a value"
    PTP_TEST_MODES="$2"
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
  require_step "${TESTS_STEP}"
  exec bash "${TESTS_STEP}"
fi

require_step "${TESTS_STEP}"
ensure_dirs
[[ -f "${SHARED_DIR}/kubeconfig" ]] \
  || die "no kubeconfig in ${SHARED_DIR}; run setup.sh first"
export T5CI_VERSION T5CI_DEPLOY_UPSTREAM HYPERVISOR_LOCAL=true
export PTP_TEST_MODES="${PTP_TEST_MODES:-}"
export L2_DISCOVERY_IMAGE="${L2_DISCOVERY_IMAGE:-quay.io/redhat-cne/l2discovery:v18}"

log "running the tests step locally (version=${T5CI_VERSION} upstream=${T5CI_DEPLOY_UPSTREAM} modes=${PTP_TEST_MODES:-all})"
exec bash "${TESTS_STEP}"
