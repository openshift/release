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

# Try to get management cluster access via OCM API
log "Attempting management cluster access..."
MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/hypershift 2>/dev/null | jq -r '.management_cluster // empty')
if [[ -n "${MC_NAME}" ]]; then
  log "Management cluster name: ${MC_NAME}"
  MANAGEMENT_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name='${MC_NAME}'" --parameter size=1 2>/dev/null | jq -r '.items[0].id // empty')
  if [[ -n "${MANAGEMENT_CLUSTER_ID}" ]]; then
    MC_LISTENING=$(ocm get /api/clusters_mgmt/v1/clusters/"${MANAGEMENT_CLUSTER_ID}" 2>/dev/null | jq -r '.api.listening // empty')
    if [[ "${MC_LISTENING}" == "external" ]]; then
      log "Management cluster ${MANAGEMENT_CLUSTER_ID} API is external, fetching kubeconfig..."
      MC_KUBECONFIG_FILE="${SHARED_DIR}/mc-kubeconfig"
      set +x
      ocm get /api/clusters_mgmt/v1/clusters/"${MANAGEMENT_CLUSTER_ID}"/credentials 2>/dev/null | jq -r '.kubeconfig' > "${MC_KUBECONFIG_FILE}"
      set -x 2>/dev/null || true
      if KUBECONFIG="${MC_KUBECONFIG_FILE}" oc whoami &>/dev/null; then
        export MC_KUBECONFIG="${MC_KUBECONFIG_FILE}"
        export MANAGEMENT_CLUSTER_ID
        log "Management cluster access established: ${MANAGEMENT_CLUSTER_ID}"
      else
        log "WARNING: MC kubeconfig fetched but failed validation (oc whoami failed), skipping MC access"
        rm -f "${MC_KUBECONFIG_FILE}"
      fi
    else
      log "Management cluster ${MANAGEMENT_CLUSTER_ID} API is ${MC_LISTENING:-unknown}, skipping MC access"
    fi
  else
    log "Could not resolve management cluster ID for ${MC_NAME}"
  fi
else
  log "No management cluster found for cluster ${CLUSTER_ID} (not HCP or hypershift info unavailable)"
fi

# Run tests
GINKGO_ARGS=("--ginkgo.junit-report=${ARTIFACT_DIR}/junit-rosa-e2e.xml" "--ginkgo.v")
log "LABEL_FILTER='${LABEL_FILTER:-}'"
if [[ -n "${LABEL_FILTER:-}" ]]; then
  GINKGO_ARGS+=("--ginkgo.label-filter=${LABEL_FILTER}")
fi

if [[ -n "${CLUSTER_TOPOLOGY:-}" ]]; then
  export CLUSTER_TOPOLOGY
fi

if [[ -n "${EXCLUDE_CLUSTER_OPERATORS:-}" ]]; then
  export EXCLUDE_CLUSTER_OPERATORS
fi

log "Running rosa-e2e tests: /usr/local/bin/e2e.test ${GINKGO_ARGS[*]}"
/usr/local/bin/e2e.test "${GINKGO_ARGS[@]}"

log "Tests complete. Results at ${ARTIFACT_DIR}/junit-rosa-e2e.xml"
