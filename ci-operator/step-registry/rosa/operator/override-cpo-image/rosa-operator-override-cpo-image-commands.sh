#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

log() {
  echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${*}\033[0m"
}

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Only override the CPO when the job is testing an openshift/hypershift PR. Periodics, manual runs,
# and release-repo rehearsals must continue using the CPO from the OCP release payload.
if [[ -z "${JOB_SPEC:-}" ]]; then
  log "JOB_SPEC is unset; keeping the CPO from the release payload"
  exit 0
fi
PULLS=$(echo "${JOB_SPEC}" | jq -r '[.refs] + (.extra_refs // []) | map(select(.org=="openshift" and .repo=="hypershift") | (.pulls // []) | length) | add // 0')
if (( PULLS == 0 )); then
  log "No openshift/hypershift PR under test; keeping the CPO from the release payload"
  exit 0
fi

CPO_IMAGE_FILE="${SHARED_DIR}/cpo-image"
if [[ ! -s "${CPO_IMAGE_FILE}" ]]; then
  log "ERROR: ${CPO_IMAGE_FILE} is missing or empty; rosa-operator-push-cpo-image must run first"
  exit 1
fi
CPO_IMAGE_REF=$(cat "${CPO_IMAGE_FILE}")
log "PR-built control plane operator image: ${CPO_IMAGE_REF}"

# Log into OCM without exposing credentials through command tracing.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
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
  log "ERROR: Cannot log into OCM; no SSO credentials or offline token are available"
  ${WAS_TRACING} && set -x
  exit 1
fi
unset SSO_CLIENT_ID SSO_CLIENT_SECRET OCM_TOKEN
${WAS_TRACING} && set -x

# Resolve the hosted cluster and its management cluster.
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r '.name')
log "Hosted cluster: ${CLUSTER_NAME} (${CLUSTER_ID})"

MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/provision_shard" | jq -r '.management_cluster')
if [[ -z "${MC_NAME}" || "${MC_NAME}" == "null" ]]; then
  log "ERROR: Failed to get the management cluster for ${CLUSTER_ID}"
  exit 1
fi
MC_CLUSTER_ID=$(ocm get /api/clusters_mgmt/v1/clusters \
  --parameter search="name is '${MC_NAME}'" | jq -r '.items[0].id')
if [[ -z "${MC_CLUSTER_ID}" || "${MC_CLUSTER_ID}" == "null" ]]; then
  log "ERROR: Failed to get the management cluster ID for ${MC_NAME}"
  exit 1
fi
log "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

MC_KUBECONFIG="${SHARED_DIR}/annotate-mc.kubeconfig"
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r '.kubeconfig' > "${MC_KUBECONFIG}"
${WAS_TRACING} && set -x
if ! KUBECONFIG="${MC_KUBECONFIG}" oc whoami &>/dev/null; then
  log "ERROR: Management cluster kubeconfig validation failed"
  exit 1
fi

case "${OCM_LOGIN_ENV}" in
  integration) NS_ENV="int" ;;
  *) NS_ENV="${OCM_LOGIN_ENV}" ;;
esac
HC_NAMESPACE="ocm-${NS_ENV}-${CLUSTER_ID}"
log "HostedCluster namespace: ${HC_NAMESPACE}"

# OCM creates the HostedCluster asynchronously, so wait for the CR before applying the override.
START_TIME=$(date +%s)
while true; do
  if KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" &>/dev/null; then
    log "Found HostedCluster '${CLUSTER_NAME}'"
    break
  fi
  elapsed=$(( $(date +%s) - START_TIME ))
  if (( elapsed >= HC_APPEAR_TIMEOUT )); then
    log "ERROR: Timed out after ${HC_APPEAR_TIMEOUT}s waiting for HostedCluster '${CLUSTER_NAME}'"
    exit 1
  fi
  log "WAITING: HostedCluster is not present yet (elapsed: ${elapsed}s); retrying in 30s"
  sleep 30
done

HCP_NAMESPACE="${HC_NAMESPACE}-${CLUSTER_NAME}"

KUBECONFIG="${MC_KUBECONFIG}" oc annotate hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" \
  "hypershift.openshift.io/control-plane-operator-image=${CPO_IMAGE_REF}" --overwrite
log "Annotated HostedCluster '${CLUSTER_NAME}' with control-plane-operator-image=${CPO_IMAGE_REF}"

# Wait for reconciliation to update the CPO Deployment, then require a healthy rollout. This makes
# it impossible for readiness checks to pass using only the old payload CPO.
ROLLOUT_START=$(date +%s)
while true; do
  # --ignore-not-found turns an absent Deployment into a quiet, empty success, so a non-zero exit
  # means a genuine API failure worth surfacing. On failure stdout is empty, so the 2>&1 capture
  # holds only the API error; reset it afterwards so the WAITING/timeout messages stay accurate.
  if ! CPO_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment control-plane-operator \
      -n "${HCP_NAMESPACE}" --ignore-not-found \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="control-plane-operator")].image}' \
      2>&1); then
    log "WARNING: oc get control-plane-operator failed: ${CPO_IMAGE}"
    CPO_IMAGE=""
  elif [[ "${CPO_IMAGE}" == "${CPO_IMAGE_REF}" ]]; then
    log "control-plane-operator Deployment now references the PR image"
    break
  fi
  elapsed=$(( $(date +%s) - ROLLOUT_START ))
  if (( elapsed >= CPO_ROLLOUT_TIMEOUT )); then
    log "ERROR: Timed out waiting for control-plane-operator to use ${CPO_IMAGE_REF} (current: ${CPO_IMAGE:-<none>})"
    exit 1
  fi
  log "WAITING: control-plane-operator image is '${CPO_IMAGE:-<none>}' (elapsed: ${elapsed}s); retrying in 10s"
  sleep 10
done

if ! KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/control-plane-operator \
  -n "${HCP_NAMESPACE}" --timeout="${CPO_ROLLOUT_TIMEOUT}s"; then
  log "ERROR: control-plane-operator rollout did not complete on the PR image"
  exit 1
fi

echo "${CPO_IMAGE_REF}" > "${SHARED_DIR}/cpo-annotation-image"
log "PR-built control-plane-operator override applied and verified on ${CLUSTER_NAME}"
