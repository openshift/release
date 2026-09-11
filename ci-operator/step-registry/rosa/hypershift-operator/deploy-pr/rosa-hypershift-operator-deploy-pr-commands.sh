#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOCK_ACQUIRED=""
MC_KUBECONFIG=""

cleanup() {
  local children
  children=$(jobs -p) || true
  if [[ -n "${children}" ]]; then
    kill ${children} && wait
  fi
  if [[ -n "${LOCK_ACQUIRED}" && -n "${MC_KUBECONFIG}" && -f "${MC_KUBECONFIG}" ]]; then
    LOCK_OWNER=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift \
      -o jsonpath='{.data.job}' 2>/dev/null || true)
    if [[ "${LOCK_OWNER}" == "${JOB_ID}" ]]; then
      echo "Releasing MC lock during cleanup..."
      KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap ho-deploy-lock -n hypershift --ignore-not-found 2>/dev/null || true
    fi
  fi
}
trap 'cleanup; exit 1' TERM INT

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in to OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

if [[ -z "${CLUSTER_SECTOR:-}" ]]; then
  echo "CLUSTER_SECTOR is required"
  exit 1
fi

if [[ -z "${HYPERSHIFT_OPERATOR_IMAGE:-}" ]]; then
  echo "HYPERSHIFT_OPERATOR_IMAGE is required (injected via dependencies)"
  exit 1
fi

echo "PR-built HO image: ${HYPERSHIFT_OPERATOR_IMAGE}"

# Resolve the MC from the sector via OSDFM API
echo "Looking up management cluster for sector '${CLUSTER_SECTOR}' in region '${REGION}'..."
MC_CLUSTER_ID=""
for status in ready maintenance; do
  MC_CLUSTER_ID=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters \
    --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${REGION}' and status in ('${status}')" \
    | jq -r '.items[0].cluster_management_reference.cluster_id // empty')
  if [[ -n "${MC_CLUSTER_ID}" ]]; then
    echo "Found MC with status '${status}'"
    break
  fi
done

if [[ -z "${MC_CLUSTER_ID}" ]]; then
  echo "No management cluster found for sector '${CLUSTER_SECTOR}' in region '${REGION}'"
  exit 1
fi

MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}" | jq -r .name)
echo "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

# Get MC kubeconfig
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG}"
echo "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
echo "${MC_CLUSTER_ID}" > "${SHARED_DIR}/mc-cluster-id"

# Acquire MC lock to prevent concurrent HO deployments
LOCK_NAME="ho-deploy-lock"
LOCK_NS="hypershift"
JOB_ID="${JOB_NAME:-unknown}-${BUILD_ID:-unknown}"

LOCK_JSON=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap "${LOCK_NAME}" -n "${LOCK_NS}" -o json 2>/dev/null || echo "")
EXISTING_LOCK=$(echo "${LOCK_JSON}" | jq -r '.data.job // empty' 2>/dev/null || true)
if [[ -n "${EXISTING_LOCK}" ]]; then
  LOCK_TIME=$(echo "${LOCK_JSON}" | jq -r '.data.acquired // empty' 2>/dev/null || true)
  LOCK_UID=$(echo "${LOCK_JSON}" | jq -r '.metadata.uid // empty' 2>/dev/null || true)
  if [[ -n "${LOCK_TIME}" ]]; then
    LOCK_EPOCH=$(date -u -d "${LOCK_TIME}" +%s 2>/dev/null || echo "0")
    NOW_EPOCH=$(date -u +%s)
    LOCK_AGE=$(( NOW_EPOCH - LOCK_EPOCH ))
    if [[ ${LOCK_AGE} -gt 14400 ]]; then
      echo "Lock is stale (${LOCK_AGE}s old, >4h). Evicting: ${EXISTING_LOCK}"
      if ! KUBECONFIG="${MC_KUBECONFIG}" oc delete configmap "${LOCK_NAME}" -n "${LOCK_NS}" --preconditions="uid=${LOCK_UID}"; then
        echo "Failed to evict stale lock (may have been replaced by another job)"
        exit 1
      fi
    else
      echo "MC is locked by another job: ${EXISTING_LOCK} (acquired: ${LOCK_TIME}, age: ${LOCK_AGE}s)"
      echo "Cannot deploy PR-built HO while another job holds the lock."
      exit 1
    fi
  else
    echo "MC is locked by another job: ${EXISTING_LOCK} (no timestamp)"
    echo "Cannot deploy PR-built HO while another job holds the lock."
    exit 1
  fi
fi

if ! KUBECONFIG="${MC_KUBECONFIG}" oc create configmap "${LOCK_NAME}" -n "${LOCK_NS}" \
  --from-literal=job="${JOB_ID}" \
  --from-literal=acquired="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=image="${HYPERSHIFT_OPERATOR_IMAGE}"; then
  echo "Failed to acquire lock — another job may have acquired it concurrently"
  exit 1
fi
LOCK_ACQUIRED="true"
echo "Acquired MC lock: ${JOB_ID}"

# Save current HO image for restoration in post steps
ORIGINAL_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[?(@.name=="operator")].image}')
echo "${ORIGINAL_IMAGE}" > "${SHARED_DIR}/ho-original-image"
echo "Current HO image on MC: ${ORIGINAL_IMAGE}"

# Extract CI registry host from the image reference
CI_REGISTRY=$(echo "${HYPERSHIFT_OPERATOR_IMAGE}" | cut -d'/' -f1)
echo "CI registry: ${CI_REGISTRY}"

# Create a pull secret on the MC for the CI registry using the pod's SA token
SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
KUBECONFIG="${MC_KUBECONFIG}" oc create secret docker-registry ci-registry-pull \
  --docker-server="${CI_REGISTRY}" \
  --docker-username=serviceaccount \
  --docker-password="${SA_TOKEN}" \
  -n hypershift \
  --dry-run=client -o yaml | KUBECONFIG="${MC_KUBECONFIG}" oc apply -f -
echo "Created CI registry pull secret on MC"

# Link the pull secret to the operator service account
KUBECONFIG="${MC_KUBECONFIG}" oc secrets link operator ci-registry-pull --for=pull -n hypershift 2>/dev/null || true

# Patch the HO deployment with the PR image and pull secret
echo "Deploying PR-built HO image to MC..."
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/operator -n hypershift \
  operator="${HYPERSHIFT_OPERATOR_IMAGE}"

# Add the pull secret to the deployment if not already present
EXISTING_PULL_SECRETS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift \
  -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null || echo "")
if ! echo " ${EXISTING_PULL_SECRETS} " | grep -q " ci-registry-pull "; then
  if [[ -z "${EXISTING_PULL_SECRETS}" ]]; then
    KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment operator -n hypershift \
      --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets","value":[{"name":"ci-registry-pull"}]}]'
  else
    KUBECONFIG="${MC_KUBECONFIG}" oc patch deployment operator -n hypershift \
      --type=json -p '[{"op":"add","path":"/spec/template/spec/imagePullSecrets/-","value":{"name":"ci-registry-pull"}}]'
  fi
fi

# Wait for rollout
echo "Waiting for HO rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/operator -n hypershift --timeout=300s

DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[?(@.name=="operator")].image}')
echo "Deployed HO image: ${DEPLOYED_IMAGE}"

READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.status.readyReplicas}')
echo "Ready replicas: ${READY_REPLICAS}"

if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  echo "HO deployment has no ready replicas after rollout!"
  exit 1
fi

echo "PR-built HyperShift operator successfully deployed to ${MC_NAME}"
