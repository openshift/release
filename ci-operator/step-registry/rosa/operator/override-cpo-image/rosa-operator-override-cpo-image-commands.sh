#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi; if [[ -n "${CPO_PULL_SECRET_FILE:-}" ]]; then rm -f "${CPO_PULL_SECRET_FILE}"; fi' EXIT TERM

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

# The CPO Deployment uses the pull-secret copied from HostedCluster.spec.pullSecret. Add a
# repository-scoped Quay credential to that source secret and wait for HyperShift to propagate it
# before applying the private image override. A path-scoped auth entry preserves any existing
# registry-wide quay.io credential needed by the cluster.
HC_PULL_SECRET_NAME=$(KUBECONFIG="${MC_KUBECONFIG}" oc get hostedcluster "${CLUSTER_NAME}" \
  -n "${HC_NAMESPACE}" -o jsonpath='{.spec.pullSecret.name}')
if [[ -z "${HC_PULL_SECRET_NAME}" ]]; then
  log "ERROR: HostedCluster '${CLUSTER_NAME}' does not reference a pull secret"
  exit 1
fi

QUAY_CREDS_DIR="/var/run/quay-credentials"
QUAY_USERNAME_FILE="${QUAY_CREDS_DIR}/username"
QUAY_CREDENTIAL_FILE="${QUAY_CREDS_DIR}/credential"
if [[ ! -r "${QUAY_USERNAME_FILE}" || ! -r "${QUAY_CREDENTIAL_FILE}" ]]; then
  log "ERROR: Quay username or credential is not available in ${QUAY_CREDS_DIR}"
  exit 1
fi

CPO_AUTH_SCOPE=$(echo "${CPO_IMAGE_REF}" | awk -F/ 'NF >= 3 { print $1 "/" $2 }')
if [[ "${CPO_AUTH_SCOPE}" != "quay.io/rosa-ci" ]]; then
  log "ERROR: Refusing to use the rosa-ci credential for unexpected image scope '${CPO_AUTH_SCOPE}'"
  exit 1
fi

CPO_PULL_SECRET_FILE=$(mktemp /tmp/rosa-cpo-pull-secret.XXXXXX)
chmod 0600 "${CPO_PULL_SECRET_FILE}"
if ! KUBECONFIG="${MC_KUBECONFIG}" oc get secret "${HC_PULL_SECRET_NAME}" -n "${HC_NAMESPACE}" \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "${CPO_PULL_SECRET_FILE}"; then
  log "ERROR: Failed to read HostedCluster pull secret '${HC_PULL_SECRET_NAME}'"
  exit 1
fi
if ! jq -e '.auths | type == "object"' "${CPO_PULL_SECRET_FILE}" >/dev/null; then
  log "ERROR: HostedCluster pull secret '${HC_PULL_SECRET_NAME}' is not valid docker config JSON"
  exit 1
fi

[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(tr -d '\r\n' < "${QUAY_USERNAME_FILE}")
QUAY_CREDENTIAL=$(tr -d '\r\n' < "${QUAY_CREDENTIAL_FILE}")
if [[ -z "${QUAY_USERNAME}" || -z "${QUAY_CREDENTIAL}" ]]; then
  log "ERROR: Quay username or credential is empty"
  unset QUAY_USERNAME QUAY_CREDENTIAL
  ${WAS_TRACING} && set -x
  exit 1
fi
QUAY_AUTH=$(printf '%s:%s' "${QUAY_USERNAME}" "${QUAY_CREDENTIAL}" | base64 -w0)
jq --arg scope "${CPO_AUTH_SCOPE}" --arg auth "${QUAY_AUTH}" \
  '.auths[$scope] = {"auth": $auth}' "${CPO_PULL_SECRET_FILE}" > "${CPO_PULL_SECRET_FILE}.new"
mv "${CPO_PULL_SECRET_FILE}.new" "${CPO_PULL_SECRET_FILE}"
unset QUAY_USERNAME QUAY_CREDENTIAL

KUBECONFIG="${MC_KUBECONFIG}" oc set data "secret/${HC_PULL_SECRET_NAME}" -n "${HC_NAMESPACE}" \
  --from-file=".dockerconfigjson=${CPO_PULL_SECRET_FILE}"
log "Added repository-scoped Quay credential to HostedCluster pull secret '${HC_PULL_SECRET_NAME}'"

PULL_SECRET_SYNC_START=$(date +%s)
while true; do
  # --ignore-not-found turns an absent secret into a quiet, empty success, so a non-zero exit means
  # a genuine API failure worth surfacing instead of silently waiting out the timeout. On failure
  # stdout is empty, so the 2>&1 capture holds only the (secret-free) API error. Keep base64/jq
  # errors on /dev/null: their stderr can echo decoded secret contents.
  if ! OC_PULL_SECRET=$(KUBECONFIG="${MC_KUBECONFIG}" oc get secret pull-secret -n "${HCP_NAMESPACE}" \
      --ignore-not-found -o jsonpath='{.data.\.dockerconfigjson}' 2>&1); then
    log "WARNING: oc get pull-secret failed: ${OC_PULL_SECRET}"
  elif [[ -n "${OC_PULL_SECRET}" ]]; then
    HCP_QUAY_AUTH=$(echo "${OC_PULL_SECRET}" | base64 -d 2>/dev/null \
      | jq -r --arg scope "${CPO_AUTH_SCOPE}" '.auths[$scope].auth // empty' 2>/dev/null || true)
    if [[ "${HCP_QUAY_AUTH}" == "${QUAY_AUTH}" ]]; then
      log "Private Quay credential propagated to hosted control plane namespace"
      break
    fi
  fi
  elapsed=$(( $(date +%s) - PULL_SECRET_SYNC_START ))
  if (( elapsed >= CPO_ROLLOUT_TIMEOUT )); then
    log "ERROR: Timed out waiting for the private Quay credential in ${HCP_NAMESPACE}/pull-secret"
    unset QUAY_AUTH HCP_QUAY_AUTH OC_PULL_SECRET
    ${WAS_TRACING} && set -x
    exit 1
  fi
  log "WAITING: Hosted control plane pull secret has not updated (elapsed: ${elapsed}s); retrying in 10s"
  sleep 10
done
unset QUAY_AUTH HCP_QUAY_AUTH OC_PULL_SECRET
${WAS_TRACING} && set -x
rm -f "${CPO_PULL_SECRET_FILE}"
CPO_PULL_SECRET_FILE=""

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
