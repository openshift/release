#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

if [[ -z "${CLUSTER_SECTOR}" ]]; then
  echo "CLUSTER_SECTOR is required"
  exit 1
fi

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

# Get MC name for logging
MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}" | jq -r .name)
echo "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

# Get MC kubeconfig
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG}"
echo "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
echo "${MC_CLUSTER_ID}" > "${SHARED_DIR}/mc-cluster-id"

# Check if the MC is locked by a PR test job
EXISTING_LOCK=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift -o jsonpath='{.data.job}' 2>/dev/null || true)
if [[ -n "${EXISTING_LOCK}" ]]; then
  LOCK_TIME=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift -o jsonpath='{.data.acquired}' 2>/dev/null || echo "unknown")
  echo "MC is locked by a PR test job: ${EXISTING_LOCK} (acquired: ${LOCK_TIME})"
  echo "Skipping HO deployment to avoid conflicting with the PR test."
  exit 0
fi

# Resolve the latest HO image from the RHTAP build pipeline (quay.io)
HO_REPO="quay.io/acm-d/rhtap-hypershift-operator"
echo "Looking up latest HO image from ${HO_REPO}..."
LATEST_DIGEST=$(curl -s "https://quay.io/api/v1/repository/acm-d/rhtap-hypershift-operator/tag/?limit=100&onlyActiveTags=true&filter_tag_name=like:latest-" \
  | jq -r '[.tags[] | select(.name | startswith("latest-"))] | sort_by(.name) | reverse | .[0].manifest_digest')

if [[ -z "${LATEST_DIGEST}" || "${LATEST_DIGEST}" == "null" ]]; then
  echo "Failed to resolve latest HO image from Quay"
  exit 1
fi

HO_IMAGE="${HO_REPO}@${LATEST_DIGEST}"
echo "Latest HO image: ${HO_IMAGE}"

# Get current HO image on the MC
CURRENT_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
echo "Current HO image on MC: ${CURRENT_IMAGE}"

if [[ "${CURRENT_IMAGE}" == "${HO_IMAGE}" ]]; then
  echo "MC is already running the latest HO image, skipping deploy"
  exit 0
fi

# Patch the HO deployment with the new image
echo "Deploying HO image to MC..."
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/operator -n hypershift \
  operator="${HO_IMAGE}"

# Wait for rollout
echo "Waiting for HO rollout..."
KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/operator -n hypershift --timeout=300s

# Verify the deployment
DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Deployed HO image: ${DEPLOYED_IMAGE}"

READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.status.readyReplicas}')
echo "Ready replicas: ${READY_REPLICAS}"

if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  echo "HO deployment has no ready replicas after rollout!"
  exit 1
fi

echo "HyperShift operator successfully deployed to ${MC_NAME}"
