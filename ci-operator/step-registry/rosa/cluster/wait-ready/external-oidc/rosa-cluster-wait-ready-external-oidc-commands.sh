#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log into OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  log "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  log "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

# Get cluster info
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_INFO=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}")
CLUSTER_NAME=$(echo "${CLUSTER_INFO}" | jq -r '.name')
log "Cluster ID: ${CLUSTER_ID}"
log "Cluster name: ${CLUSTER_NAME}"

# This step only applies to clusters that were provisioned with external
# authentication (external OIDC) enabled. For any other cluster there is nothing
# to verify, so exit successfully.
EXTERNAL_AUTH_CONFIG=$(echo "${CLUSTER_INFO}" | jq -r '.external_auth_config.enabled // false')
if [[ "${EXTERNAL_AUTH_CONFIG}" != "true" ]]; then
  log "Cluster ${CLUSTER_ID} does not have external authentication enabled; nothing to verify."
  exit 0
fi

# Global timeout tracking
START_TIME=$(date +%s)

wait_for() {
  local description="$1"
  shift
  log "Checking ${description}..."
  while true; do
    if "$@"; then
      log "PASSED: ${description}"
      return 0
    fi
    elapsed=$(( $(date +%s) - START_TIME ))
    if (( elapsed >= EXTERNAL_OIDC_READY_TIMEOUT )); then
      log "ERROR: Timed out after ${EXTERNAL_OIDC_READY_TIMEOUT}s waiting for: ${description}"
      return 1
    fi
    log "WAITING: ${description} (elapsed: ${elapsed}s), retrying in 60s..."
    sleep 60
  done
}

# 1. Verify the external auth provider is registered/configured in OCM.
#    rosa-conf-external-oidc-create issues `rosa create external-auth-provider`,
#    which can return before the provider is reconciled onto the hosted control
#    plane, so poll until at least one external auth entry is present.
EXTERNAL_AUTHS_URL="/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/external_auth_config/external_auths"
check_provider_configured() {
  local providers count degraded
  providers=$(ocm get "${EXTERNAL_AUTHS_URL}" 2>/dev/null) || return 1
  count=$(echo "${providers}" | jq -r '.items | length // 0')
  if (( count < 1 )); then
    log "No external auth providers reported yet."
    return 1
  fi
  # If the provider exposes status conditions, make sure none report a failure.
  degraded=$(echo "${providers}" | jq -r \
    '[.items[].status.conditions[]? | select(.status=="True") | select(.type|test("Degraded|Error|Failed";"i"))] | length' 2>/dev/null || echo 0)
  if [[ "${degraded}" =~ ^[0-9]+$ ]] && (( degraded > 0 )); then
    log "External auth provider reports a failing condition."
    return 1
  fi
  log "External auth provider(s) configured: $(echo "${providers}" | jq -r '[.items[].id] | join(", ")')"
  return 0
}
wait_for "external auth provider configured on cluster ${CLUSTER_NAME}" check_provider_configured

# 2. Verify the hosted control plane kube-apiserver has rolled out on the
#    management cluster after external auth was enabled. Enabling external auth
#    reconfigures the kube-apiserver (new rollout/restart); confirming the
#    rollout completed proves the external OIDC configuration was applied.
log "Retrieving management cluster info..."
MC_NAME=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}"/provision_shard | jq -r '.management_cluster')
if [[ -z "${MC_NAME}" || "${MC_NAME}" == "null" ]]; then
  log "ERROR: Failed to get management cluster name for cluster ${CLUSTER_ID}"
  exit 1
fi
log "Management cluster name: ${MC_NAME}"

MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id')
if [[ -z "${MC_CLUSTER_ID}" || "${MC_CLUSTER_ID}" == "null" ]]; then
  log "ERROR: Failed to get management cluster ID for ${MC_NAME}"
  exit 1
fi
log "Management cluster ID: ${MC_CLUSTER_ID}"

log "Fetching management cluster kubeconfig..."
MC_KUBECONFIG="${SHARED_DIR}/hcp-mc.kubeconfig"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r '.kubeconfig' > "${MC_KUBECONFIG}"
$WAS_TRACING && set -x

if ! KUBECONFIG="${MC_KUBECONFIG}" oc whoami &>/dev/null; then
  log "ERROR: MC kubeconfig validation failed (oc whoami failed)"
  exit 1
fi
log "Management cluster access established"

# HCP namespace: ocm-<env>-<cluster_id>-<cluster_name>
# The namespace env token is the OCM short name, which differs from OCM_LOGIN_ENV:
# integration -> int (staging and production match their login env verbatim).
case "${OCM_LOGIN_ENV}" in
  integration) NS_ENV="int" ;;
  *)           NS_ENV="${OCM_LOGIN_ENV}" ;;
esac
HCP_NAMESPACE="ocm-${NS_ENV}-${CLUSTER_ID}-${CLUSTER_NAME}"
log "HCP namespace: ${HCP_NAMESPACE}"

check_kube_apiserver_rollout() {
  local dep
  dep=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment kube-apiserver -n "${HCP_NAMESPACE}" -o json 2>/dev/null) || return 1
  echo "${dep}" | jq -e '
    (.status.observedGeneration // 0) >= (.metadata.generation // 0)
    and (.spec.replicas // 0) > 0
    and (.status.updatedReplicas // 0) == (.spec.replicas // 0)
    and (.status.readyReplicas // 0) == (.spec.replicas // 0)
    and (.status.unavailableReplicas // 0) == 0
  ' >/dev/null 2>&1
}
wait_for "kube-apiserver rollout complete in ${HCP_NAMESPACE}" check_kube_apiserver_rollout

check_kube_apiserver_pods() {
  local pods not_ready
  pods=$(KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" -l app=kube-apiserver --no-headers 2>/dev/null) || return 1
  if [[ -z "${pods}" ]]; then
    log "No kube-apiserver pods found yet."
    return 1
  fi
  not_ready=$(echo "${pods}" | grep -v -E "Running|Completed|Succeeded" || true)
  [[ -z "${not_ready}" ]]
}
wait_for "kube-apiserver pods running in ${HCP_NAMESPACE}" check_kube_apiserver_pods
KUBECONFIG="${MC_KUBECONFIG}" oc get pods -n "${HCP_NAMESPACE}" -l app=kube-apiserver -o wide || true

log "External OIDC readiness checks passed: provider configured and kube-apiserver rolled out."
