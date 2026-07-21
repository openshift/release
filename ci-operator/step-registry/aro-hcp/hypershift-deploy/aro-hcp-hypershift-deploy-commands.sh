#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Source runtime slot contract (LOCATION, LEASED_MSI_CONTAINERS, etc.)
env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi
export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by slot.env or env}"

# --- Resolve ARO-HCP service images from dev ACR by main commit SHA ---
# The images-push-postsubmit job publishes service images on every merge
# to ARO-HCP main, tagged with the 7-char commit SHA. We resolve images
# by SHA to guarantee version coherence across all services.

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

set +o xtrace
az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none
set -o xtrace

CONFIG_FILE="${SHARED_DIR}/config.yaml"
ACR_NAME=$(yq '.acr.svc.name' "${CONFIG_FILE}")
ACR_URL="${ACR_NAME}.azurecr.io"

BACKEND_REPO=$(yq '.backend.image.repository' "${CONFIG_FILE}")
FRONTEND_REPO=$(yq '.frontend.image.repository' "${CONFIG_FILE}")
ADMIN_API_REPO=$(yq '.adminApi.image.repository' "${CONFIG_FILE}")
SESSIONGATE_REPO=$(yq '.sessiongate.image.repository' "${CONFIG_FILE}")
FLEET_REPO=$(yq '.fleet.image.repository' "${CONFIG_FILE}")
MGMT_AGENT_REPO=$(yq '.mgmtAgent.image.repository' "${CONFIG_FILE}")
KUBE_APPLIER_REPO=$(yq '.kubeApplier.image.repository' "${CONFIG_FILE}")

MAIN_SHA=$(git ls-remote https://github.com/Azure/ARO-HCP.git main | cut -c1-7)
echo "ARO-HCP main HEAD: ${MAIN_SHA}"
echo "ACR: ${ACR_URL}"

MAX_POLL=30
POLL_INTERVAL=30
echo "Polling ACR for ${FLEET_REPO}:${MAIN_SHA} (up to $((MAX_POLL * POLL_INTERVAL))s) ..."
FOUND_HEAD=false
for attempt in $(seq 1 ${MAX_POLL}); do
  if az acr manifest show -r "${ACR_NAME}" -n "${FLEET_REPO}:${MAIN_SHA}" &>/dev/null; then
    echo "Images for HEAD (${MAIN_SHA}) available after attempt ${attempt}"
    FOUND_HEAD=true
    break
  fi
  echo "Attempt ${attempt}/${MAX_POLL}: not yet available, retrying in ${POLL_INTERVAL}s ..."
  sleep ${POLL_INTERVAL}
done

if [[ "${FOUND_HEAD}" != "true" ]]; then
  echo "Images for HEAD (${MAIN_SHA}) not found after polling. Walking back through history ..."
  MAX_WALK=20
  FOUND_SHA=""
  for sha in $(curl -sS "https://api.github.com/repos/Azure/ARO-HCP/commits?sha=main&per_page=${MAX_WALK}" | jq -r '.[].sha' | cut -c1-7 | tail -n +2); do
    if az acr manifest show -r "${ACR_NAME}" -n "${FLEET_REPO}:${sha}" &>/dev/null; then
      FOUND_SHA="${sha}"
      echo "Found images in ACR for commit ${sha}"
      break
    fi
    echo "  ${sha}: not in ACR, trying older ..."
  done

  if [[ -z "${FOUND_SHA}" ]]; then
    echo "ERROR: No images found in ${ACR_NAME} for any of the last ${MAX_WALK} main commits."
    exit 1
  fi
  MAIN_SHA="${FOUND_SHA}"
fi

resolve_digest() {
  local repo=$1 tag=$2
  local digest
  digest=$(az acr manifest show-metadata -r "${ACR_NAME}" -n "${repo}:${tag}" --query 'digest' -o tsv)
  if [[ -z "${digest}" ]]; then
    echo "ERROR: Failed to resolve digest for ${repo}:${tag}" >&2
    return 1
  fi
  echo "${digest}"
}

echo "Resolving image digests for ARO-HCP main commit ${MAIN_SHA} ..."
BACKEND_DIGEST=$(resolve_digest "${BACKEND_REPO}" "${MAIN_SHA}")
FRONTEND_DIGEST=$(resolve_digest "${FRONTEND_REPO}" "${MAIN_SHA}")
ADMIN_API_DIGEST=$(resolve_digest "${ADMIN_API_REPO}" "${MAIN_SHA}")
SESSIONGATE_DIGEST=$(resolve_digest "${SESSIONGATE_REPO}" "${MAIN_SHA}")
FLEET_DIGEST=$(resolve_digest "${FLEET_REPO}" "${MAIN_SHA}")
MGMT_AGENT_DIGEST=$(resolve_digest "${MGMT_AGENT_REPO}" "${MAIN_SHA}")
KUBE_APPLIER_DIGEST=$(resolve_digest "${KUBE_APPLIER_REPO}" "${MAIN_SHA}")

echo "Resolved digests:"
echo "  backend:      ${BACKEND_DIGEST}"
echo "  frontend:     ${FRONTEND_DIGEST}"
echo "  admin-api:    ${ADMIN_API_DIGEST}"
echo "  sessiongate:  ${SESSIONGATE_DIGEST}"
echo "  fleet:        ${FLEET_DIGEST}"
echo "  mgmt-agent:   ${MGMT_AGENT_DIGEST}"
echo "  kube-applier: ${KUBE_APPLIER_DIGEST}"

export BACKEND_IMAGE="${ACR_URL}/${BACKEND_REPO}@${BACKEND_DIGEST}"
export FRONTEND_IMAGE="${ACR_URL}/${FRONTEND_REPO}@${FRONTEND_DIGEST}"
export ADMIN_API_IMAGE="${ACR_URL}/${ADMIN_API_REPO}@${ADMIN_API_DIGEST}"
export SESSIONGATE_IMAGE="${ACR_URL}/${SESSIONGATE_REPO}@${SESSIONGATE_DIGEST}"
export FLEET_IMAGE="${ACR_URL}/${FLEET_REPO}@${FLEET_DIGEST}"
export MGMT_AGENT_IMAGE="${ACR_URL}/${MGMT_AGENT_REPO}@${MGMT_AGENT_DIGEST}"
export KUBE_APPLIER_IMAGE="${ACR_URL}/${KUBE_APPLIER_REPO}@${KUBE_APPLIER_DIGEST}"

set +x
exec hack/ci/provision-environment.sh
