#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Private clusters ship proxy-conf.sh so oc / e2e.test reach the private API
# through the corp proxy. No-op for public clusters.
if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  log "Private cluster detected, sourcing proxy configuration"
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# The backplane hosted-cluster kubeconfig (bp-kubeconfig, written by
# rosa-backplane-login) is exported as its own BP_KUBECONFIG env var so the suite
# can initialise a backplane client from it directly. This is the only credential
# that reaches private-link clusters, whose API server is not routable from the
# build farm (ROSAENG-67580 contract).
if [[ -s "${SHARED_DIR}/bp-kubeconfig" ]]; then
  export BP_KUBECONFIG="${SHARED_DIR}/bp-kubeconfig"
  log "Backplane hosted-cluster kubeconfig available at BP_KUBECONFIG=${BP_KUBECONFIG}"
fi

# Customer plane validates from the guest cluster kubeconfig. Prefer the
# provisioner-written kubeconfig (direct API), and fall back to BP_KUBECONFIG for
# private-link clusters until the suite consumes BP_KUBECONFIG on its own.
if [[ -s "${SHARED_DIR}/kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
  log "Using customer-plane kubeconfig at ${KUBECONFIG}"
elif [[ -n "${BP_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${BP_KUBECONFIG}"
  log "Direct kubeconfig absent; using backplane hosted-cluster kubeconfig at ${KUBECONFIG}"
else
  log "ERROR: neither ${SHARED_DIR}/kubeconfig nor ${SHARED_DIR}/bp-kubeconfig found;"
  log "       run the provisioner and rosa-backplane-login before this step"
  exit 1
fi

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${REGION:-${LEASED_RESOURCE}}"
  export AWS_REGION="${REGION:-${LEASED_RESOURCE}}"
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
export CLUSTER_ID OCM_ENV="${OCM_LOGIN_ENV}"

# Self-select feature assertions from the frozen contract metadata (ROSAENG-67580)
# instead of per-job config: export each feature flag as FEATURE_<NAME> and the
# topology so the suite enables/skips the right specs.
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

GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e-customer.xml" "--ginkgo.v")
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi

log "Running customer-plane validation: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"
log "Customer-plane validation complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e-customer.xml"
