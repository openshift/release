#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Configure AWS
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
else
  log "No AWS credentials found in cluster profile"
fi

# Log into OCM
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  log "No OCM credentials found in cluster profile"
  exit 1
fi

# Get cluster info from shared dir
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
log "Testing cluster: ${CLUSTER_ID}"

OCM_TOKEN=$(ocm token)
export OCM_TOKEN
export OCM_ENV="${OCM_LOGIN_ENV}"
export CLUSTER_ID
export AWS_REGION="${LEASED_RESOURCE}"

# Set CLUSTER_TOPOLOGY so the test binary knows the cluster type without an extra OCM API call
if [[ "${HOSTED_CP:-false}" == "true" ]]; then
  export CLUSTER_TOPOLOGY="hcp"
else
  export CLUSTER_TOPOLOGY="classic"
fi
log "Cluster topology: ${CLUSTER_TOPOLOGY}"

# Try to get MC access via backplane (HCP only)
if [[ "${CLUSTER_TOPOLOGY}" == "hcp" ]]; then
  log "Attempting MC access via backplane..."
  if ocm backplane login "${CLUSTER_ID}" --manager 2>/dev/null; then
    export MC_KUBECONFIG="${HOME}/.kube/config"
    MC_SERVER=$(oc whoami --show-server 2>/dev/null || true)
    if [[ "${MC_SERVER}" == *"backplane"* ]]; then
      MANAGEMENT_CLUSTER_ID=$(echo "${MC_SERVER}" | sed 's|.*/cluster/||; s|/.*||')
      export MANAGEMENT_CLUSTER_ID
      log "MC access established: ${MANAGEMENT_CLUSTER_ID}"
    fi
  fi
fi

# Run tests
GINKGO_FLAGS="--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e.xml --ginkgo.v"
if [[ -n "${LABEL_FILTER}" ]]; then
  GINKGO_FLAGS="${GINKGO_FLAGS} --ginkgo.label-filter=${LABEL_FILTER}"
fi

if [[ -n "${EXCLUDE_CLUSTER_OPERATORS}" ]]; then
  export EXCLUDE_CLUSTER_OPERATORS
fi

log "Running rosa-e2e tests..."
/usr/local/bin/e2e.test ${GINKGO_FLAGS}

log "Tests complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e.xml"
