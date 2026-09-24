#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Platform plane validates from the management cluster kubeconfig produced by
# rosa-backplane-login. Without it there is nothing to validate here.
MC_KUBECONFIG_FILE="${SHARED_DIR}/mc-kubeconfig"
if [[ ! -s "${MC_KUBECONFIG_FILE}" ]]; then
  log "ERROR: ${MC_KUBECONFIG_FILE} not found; run rosa-backplane-login before this step"
  exit 1
fi
export KUBECONFIG="${MC_KUBECONFIG_FILE}"
export MC_KUBECONFIG="${MC_KUBECONFIG_FILE}"
log "Using management-cluster kubeconfig at ${MC_KUBECONFIG_FILE}"

if [[ -s "${SHARED_DIR}/sc-kubeconfig" ]]; then
  export SC_KUBECONFIG="${SHARED_DIR}/sc-kubeconfig"
  log "Service-cluster kubeconfig available at ${SC_KUBECONFIG}"
else
  log "No sc-kubeconfig present; service-cluster specs will be skipped"
fi
if [[ -s "${SHARED_DIR}/mc-cluster-id" ]]; then
  MANAGEMENT_CLUSTER_ID=$(cat "${SHARED_DIR}/mc-cluster-id")
  export MANAGEMENT_CLUSTER_ID
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
export CLUSTER_ID OCM_ENV="${OCM_LOGIN_ENV}"

# Self-select feature assertions from the frozen contract metadata (ROSAENG-67580).
META="${SHARED_DIR}/cluster-metadata.json"
if [[ -s "${META}" ]]; then
  while IFS="=" read -r k v; do
    [[ -n "${k}" ]] && export "FEATURE_${k^^}=${v}"
  done < <(jq -r '.feature_flags // {} | to_entries[] | "\(.key)=\(.value)"' "${META}")
  if [[ -z "${CLUSTER_TOPOLOGY:-}" ]]; then
    CLUSTER_TOPOLOGY=$(jq -r '.topology // empty' "${META}")
    [[ -n "${CLUSTER_TOPOLOGY}" ]] && export CLUSTER_TOPOLOGY
  fi
  log "Loaded feature flags from cluster-metadata.json (topology=${CLUSTER_TOPOLOGY:-unset})"
else
  log "WARNING: ${META} not found; running without contract-driven feature selection"
fi

GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e-platform.xml" "--ginkgo.v")
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi

log "Running platform-plane validation: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"
log "Platform-plane validation complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e-platform.xml"
