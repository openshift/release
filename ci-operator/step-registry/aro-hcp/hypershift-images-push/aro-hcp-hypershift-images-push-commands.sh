#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set +o xtrace

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Azure login
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
AZURE_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export AZURE_SUBSCRIPTION_ID

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

# Resolve ACR names from rendered config
CONFIG_FILE="${SHARED_DIR}/config.yaml"
SVC_ACR_NAME=$(yq '.acr.svc.name' "${CONFIG_FILE}")
SVC_ACR_URL="${SVC_ACR_NAME}.azurecr.io"
OCP_ACR_NAME=$(yq '.acr.ocp.name' "${CONFIG_FILE}")
OCP_ACR_URL="${OCP_ACR_NAME}.azurecr.io"
echo "SVC ACR: ${SVC_ACR_URL} (HO image)"
echo "OCP ACR: ${OCP_ACR_URL} (CPO image)"

# Authenticate to CI registry
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers" "${HOME}/.docker"
oc registry login

# Authenticate to both ACRs
SVC_ACR_TOKEN=$(az acr login --name "${SVC_ACR_NAME}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${SVC_ACR_URL}" --auth-basic="00000000-0000-0000-0000-000000000000:${SVC_ACR_TOKEN}"

OCP_ACR_TOKEN=$(az acr login --name "${OCP_ACR_NAME}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${OCP_ACR_URL}" --auth-basic="00000000-0000-0000-0000-000000000000:${OCP_ACR_TOKEN}"

IMAGE_TAG="hypershift-pr-${PULL_NUMBER:-unknown}-$(date +%s)"

retry() {
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then
      return 0
    fi
    echo "Attempt ${attempt}/3 failed, retrying in 10s..."
    sleep 10
  done
  echo "Command failed after 3 attempts: $*"
  return 1
}

# Push hypershift-operator (HO) image to SVC ACR
HO_ACR_REF="${SVC_ACR_URL}/hypershift-operator:${IMAGE_TAG}"
echo "Pushing hypershift-operator: ${HYPERSHIFT_OPERATOR_IMAGE} -> ${HO_ACR_REF}"
retry oc image mirror "${HYPERSHIFT_OPERATOR_IMAGE}" "${HO_ACR_REF}"

# Push control-plane-operator (CPO) image to OCP ACR.
# The CPO runs in HCP namespaces on the management cluster, which have pull
# credentials for the OCP ACR (arohcpocpdev) but not the SVC ACR. Normal
# (non-override) CPO images come from the OCP release payload and land in
# the OCP ACR via registryOverrides, so the override must go there too.
CPO_ACR_REF="${OCP_ACR_URL}/hypershift:${IMAGE_TAG}"
echo "Pushing control-plane-operator: ${HYPERSHIFT_CPO_IMAGE} -> ${CPO_ACR_REF}"
retry oc image mirror "${HYPERSHIFT_CPO_IMAGE}" "${CPO_ACR_REF}"

# Resolve digests from ACR for the pushed images.
# ACR metadata can lag behind a successful push, so retry the query.
resolve_digest() {
    local acr_url="$1" repo="$2" tag="$3"
    local digest=""
    for attempt in 1 2 3 4 5; do
        digest=$(az acr manifest list-metadata "${acr_url}/${repo}" \
            --query "[?contains(tags, '${tag}')].digest" -o tsv 2>/dev/null || true)
        if [[ -n "${digest}" ]]; then
            echo "${digest}"
            return 0
        fi
        if (( attempt < 5 )); then
            echo "Digest not yet available for ${repo}:${tag} from ${acr_url} (attempt ${attempt}/5), retrying in 15s..." >&2
            sleep 15
        fi
    done
    return 1
}

HO_DIGEST=$(resolve_digest "${SVC_ACR_URL}" "hypershift-operator" "${IMAGE_TAG}")
echo "HO digest: ${HO_DIGEST}"

CPO_DIGEST=$(resolve_digest "${OCP_ACR_URL}" "hypershift" "${IMAGE_TAG}")
echo "CPO digest: ${CPO_DIGEST}"

if [[ -z "${HO_DIGEST}" ]]; then
    echo "ERROR: Failed to resolve digest for hypershift-operator:${IMAGE_TAG} from ${SVC_ACR_URL}"
    exit 1
fi
if [[ -z "${CPO_DIGEST}" ]]; then
    echo "ERROR: Failed to resolve digest for hypershift:${IMAGE_TAG} from ${OCP_ACR_URL}"
    exit 1
fi

# Write HO config overlay for the downstream provision step to merge.
# The installer constructs the HO image as:
#   {acr.svc.name}.{acrDNSSuffix}/{hypershift.image.repository}@{hypershift.image.digest}
# so we only need to override repository and digest (registry is always the service ACR).
HYPERSHIFT_OVERRIDES="${SHARED_DIR}/hypershift-image-overrides.yaml"
DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"

export _YQ_REG="${SVC_ACR_URL}"
export _YQ_REPO="hypershift-operator"
export _YQ_DIG="${HO_DIGEST}"
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.registry = strenv(_YQ_REG) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.repository = strenv(_YQ_REPO) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.digest = strenv(_YQ_DIG)
" > "${HYPERSHIFT_OVERRIDES}"
unset _YQ_REG _YQ_REPO _YQ_DIG

echo "Created hypershift image overrides at ${HYPERSHIFT_OVERRIDES}:"
cat "${HYPERSHIFT_OVERRIDES}"

# Write CPO image ref for e2e tests to use as an ARM resource tag.
# The CPO override is applied via the aro-hcp.experimental.cluster.
# control-plane-operator-image-override tag (AFEC-gated), not a config key.
CPO_OVERRIDE_FILE="${SHARED_DIR}/hypershift-cpo-override.env"
echo "export CPO_IMAGE_OVERRIDE=\"${OCP_ACR_URL}/hypershift@${CPO_DIGEST}\"" > "${CPO_OVERRIDE_FILE}"
echo "Created CPO override env at ${CPO_OVERRIDE_FILE}:"
cat "${CPO_OVERRIDE_FILE}"

echo "All hypershift images pushed successfully."
echo "HO: ${SVC_ACR_URL}/hypershift-operator@${HO_DIGEST}"
echo "CPO: ${OCP_ACR_URL}/hypershift@${CPO_DIGEST}"
