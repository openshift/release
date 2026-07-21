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

# Resolve ACR name from rendered config
CONFIG_FILE="${SHARED_DIR}/config.yaml"
ACR_NAME=$(yq '.acr.svc.name' "${CONFIG_FILE}")
ACR_URL="${ACR_NAME}.azurecr.io"
echo "Target ACR: ${ACR_URL}"

# Authenticate to CI registry
export XDG_RUNTIME_DIR="/tmp/run"
mkdir -p "${XDG_RUNTIME_DIR}/containers" "${HOME}/.docker"
oc registry login

# Authenticate to ACR
ACR_TOKEN=$(az acr login --name "${ACR_NAME}" --expose-token --output tsv --query accessToken)
oc registry login --registry "${ACR_URL}" --auth-basic="00000000-0000-0000-0000-000000000000:${ACR_TOKEN}"

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

# Push hypershift-operator (HO) image to ACR
HO_ACR_REF="${ACR_URL}/hypershift-operator:${IMAGE_TAG}"
echo "Pushing hypershift-operator: ${HYPERSHIFT_OPERATOR_IMAGE} -> ${HO_ACR_REF}"
retry oc image mirror "${HYPERSHIFT_OPERATOR_IMAGE}" "${HO_ACR_REF}"

# Push control-plane-operator (CPO) image to ACR
CPO_ACR_REF="${ACR_URL}/hypershift:${IMAGE_TAG}"
echo "Pushing control-plane-operator: ${HYPERSHIFT_CPO_IMAGE} -> ${CPO_ACR_REF}"
retry oc image mirror "${HYPERSHIFT_CPO_IMAGE}" "${CPO_ACR_REF}"

# Resolve digests from ACR for the pushed images.
# Use `az acr manifest list-metadata` which reliably returns digests,
# matching the pattern used by the aro-hcp-hypershift-deploy step.
HO_DIGEST=$(az acr manifest list-metadata "${ACR_URL}/hypershift-operator" \
    --query "[?tags[0]=='${IMAGE_TAG}'].digest" -o tsv)
echo "HO digest: ${HO_DIGEST}"

CPO_DIGEST=$(az acr manifest list-metadata "${ACR_URL}/hypershift" \
    --query "[?tags[0]=='${IMAGE_TAG}'].digest" -o tsv)
echo "CPO digest: ${CPO_DIGEST}"

if [[ -z "${HO_DIGEST}" ]]; then
    echo "ERROR: Failed to resolve digest for hypershift-operator:${IMAGE_TAG} from ${ACR_URL}"
    exit 1
fi
if [[ -z "${CPO_DIGEST}" ]]; then
    echo "ERROR: Failed to resolve digest for hypershift:${IMAGE_TAG} from ${ACR_URL}"
    exit 1
fi

# Write HO config overlay for the downstream provision step to merge.
# The installer constructs the HO image as:
#   {acr.svc.name}.{acrDNSSuffix}/{hypershift.image.repository}@{hypershift.image.digest}
# so we only need to override repository and digest (registry is always the service ACR).
HYPERSHIFT_OVERRIDES="${SHARED_DIR}/hypershift-image-overrides.yaml"
DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"

export _YQ_REG="${ACR_URL}"
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
echo "export CPO_IMAGE_OVERRIDE=\"${ACR_URL}/hypershift@${CPO_DIGEST}\"" > "${CPO_OVERRIDE_FILE}"
echo "Created CPO override env at ${CPO_OVERRIDE_FILE}:"
cat "${CPO_OVERRIDE_FILE}"

echo "All hypershift images pushed successfully."
echo "HO: ${ACR_URL}/hypershift-operator@${HO_DIGEST}"
echo "CPO: ${ACR_URL}/hypershift@${CPO_DIGEST}"
