#!/bin/bash
# Shared configuration for the telco5g PTP phase commands.
#
# The commands in this directory are thin entry points: they prepare the
# environment and run the same step-registry commands that CI runs. There is no
# separate local implementation.
#
#   setup.sh   -> ci-operator/step-registry/telco5g/ptp-cluster-setup
#   tests.sh   -> ci-operator/step-registry/telco5g/ptp/tests
#   gather.sh  -> ci-operator/step-registry/telco5g/ptp/gather
#
# In a ci-operator pod the step scripts run unchanged (SSH to the hypervisor).
# On the hypervisor the wrappers export HYPERVISOR_LOCAL=true, which makes the
# same scripts run their commands locally instead of over SSH.
#
# This file is sourced by the three commands; it is not meant to run alone.

set -o nounset
set -o pipefail

TELCO5G_PTP_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TELCO5G_PTP_STEP_BASE="${TELCO5G_PTP_REPO_ROOT}/ci-operator/step-registry/telco5g"
export SETUP_STEP="${TELCO5G_PTP_STEP_BASE}/ptp-cluster-setup/telco5g-ptp-cluster-setup-commands.sh"
export TESTS_STEP="${TELCO5G_PTP_STEP_BASE}/ptp/tests/telco5g-ptp-tests-commands.sh"
export GATHER_STEP="${TELCO5G_PTP_STEP_BASE}/ptp/gather/telco5g-ptp-gather-commands.sh"

# ci-operator mounts the job SSH key at this path and exports the two
# directories the steps use to hand data to each other.
TELCO5G_PTP_CI_MODE=false
if [[ -r /var/run/ci-key/cikey && -n "${SHARED_DIR:-}" && -n "${ARTIFACT_DIR:-}" ]]; then
  TELCO5G_PTP_CI_MODE=true
fi

if [[ "${TELCO5G_PTP_CI_MODE}" != "true" ]]; then
  T5CI_VERSION="${T5CI_VERSION:-5.1}"

  # Track whether KCLI_PARAM came from the environment: setup.sh rebuilds it
  # from --version unless the caller passed one explicitly.
  export TELCO5G_PTP_KCLI_PARAM_EXPLICIT=false
  if [[ -n "${KCLI_PARAM:-}" ]]; then
    export TELCO5G_PTP_KCLI_PARAM_EXPLICIT=true
  fi
  export KCLI_PARAM="${KCLI_PARAM:--P tag=${T5CI_VERSION} -P version=nightly}"

  export BASE_DIR="${TELCO5G_PTP_DIR:-${HOME}/telco5g-ptp}"
  export SHARED_DIR="${BASE_DIR}/shared"
  export ARTIFACT_DIR="${BASE_DIR}/artifacts"
  export LOG_DIR="${BASE_DIR}/logs"
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '[%s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_step() {
  local path="$1"
  [[ -r "${path}" ]] || die "missing step script ${path}; run this command from an openshift/release checkout"
}

ensure_dirs() {
  mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}" "${LOG_DIR}"
}
