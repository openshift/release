#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export INFRA_SUBSCRIPTION_ID
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
oc version
kubelogin --version

BACKEND_DIGEST=$(echo ${BACKEND_IMAGE} | cut -d'@' -f2)
BACKEND_REPOSITORY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
BACKEND_SOURCE_REGISTRY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${BACKEND_SOURCE_REGISTRY} and repo ${BACKEND_REPOSITORY} for Backend Image"

FRONTEND_DIGEST=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f2)
FRONTEND_REPOSITORY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
FRONTEND_SOURCE_REGISTRY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${FRONTEND_SOURCE_REGISTRY} and repo ${FRONTEND_REPOSITORY} for Frontend Image"

ADMIN_API_DIGEST=$(echo ${ADMIN_API_IMAGE} | cut -d'@' -f2)
ADMIN_API_REPOSITORY=$(echo ${ADMIN_API_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
ADMIN_API_SOURCE_REGISTRY=$(echo ${ADMIN_API_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${ADMIN_API_SOURCE_REGISTRY} and repo ${ADMIN_API_REPOSITORY} for Admin API Image"

SESSIONGATE_DIGEST=$(echo ${SESSIONGATE_IMAGE} | cut -d'@' -f2)
SESSIONGATE_REPOSITORY=$(echo ${SESSIONGATE_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
SESSIONGATE_SOURCE_REGISTRY=$(echo ${SESSIONGATE_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${SESSIONGATE_SOURCE_REGISTRY} and repo ${SESSIONGATE_REPOSITORY} for SessionGate Image"

HCP_RECOVERY_DIGEST=$(echo ${HCP_RECOVERY_IMAGE} | cut -d'@' -f2)
HCP_RECOVERY_REPOSITORY=$(echo ${HCP_RECOVERY_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
HCP_RECOVERY_SOURCE_REGISTRY=$(echo ${HCP_RECOVERY_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${HCP_RECOVERY_SOURCE_REGISTRY} and repo ${HCP_RECOVERY_REPOSITORY} for HCP Recovery Image"

# Set up registries that require oc login - append backend and frontend registries
if [[ -n "${USE_OC_LOGIN_REGISTRIES}" ]]; then
    USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${HCP_RECOVERY_SOURCE_REGISTRY}"
else
    USE_OC_LOGIN_REGISTRIES="${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${HCP_RECOVERY_SOURCE_REGISTRY}"
fi
echo "USE_OC_LOGIN_REGISTRIES set to: ${USE_OC_LOGIN_REGISTRIES}"

OVERRIDE_CONFIG_FILE="${SHARED_DIR}/config-override.yaml"

MSI_MOCK_CLIENT_ID=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".clientId" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
MSI_MOCK_PRINCIPAL_ID=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".principalId" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
MSI_MOCK_CERT_NAME=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".certName" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
echo "MSI mock SP override: ${LEASED_MSI_MOCK_SP} -> clientId=${MSI_MOCK_CLIENT_ID}"

yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.registry = \"${BACKEND_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.repository = \"${BACKEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.digest = \"${BACKEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.registry = \"${FRONTEND_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.repository = \"${FRONTEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.digest = \"${FRONTEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.registry = \"${ADMIN_API_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.repository = \"${ADMIN_API_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.digest = \"${ADMIN_API_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.registry = \"${SESSIONGATE_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.repository = \"${SESSIONGATE_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.digest = \"${SESSIONGATE_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockClientId = \"${MSI_MOCK_CLIENT_ID}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockPrincipalId = \"${MSI_MOCK_PRINCIPAL_ID}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockCertName = \"${MSI_MOCK_CERT_NAME}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.registry = \"${HCP_RECOVERY_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.repository = \"${HCP_RECOVERY_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.digest = \"${HCP_RECOVERY_DIGEST}\"
" > "${OVERRIDE_CONFIG_FILE}"
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

CONFIG_PROV="${SHARED_DIR}/config-prov.yaml"

# There's a $SHARED_DIR/config.yaml already from the write-config step
# but it is of limited accuracy. It's fine for int/stg/prod, but this prov
# step will generate temporary names for a bunch of things, so if we want
# following steps to know what those are, we need to override the older
# less accurate config.yaml.
# And let's do it in a way that works even if provisioning ends up failing.
finalize() {
    if [[ -s "${CONFIG_PROV}" ]]; then
        mv "${CONFIG_PROV}" "${SHARED_DIR}/config.yaml"
        cp "${SHARED_DIR}/config.yaml" "${ARTIFACT_DIR}/config.yaml"
    fi
}
trap finalize EXIT

unset GOFLAGS
make -o tooling/templatize/templatize entrypoint/Region \
  DEPLOY_ENV="${DEPLOY_ENV}" \
  OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}" \
  EXTRA_ARGS="--region ${LOCATION} --abort-if-regional-exist" \
  TIMING_OUTPUT=${SHARED_DIR}/steps.yaml.gz \
  ENTRYPOINT_JUNIT_OUTPUT=${ARTIFACT_DIR}/junit_entrypoint.xml \
  CONFIG_OUTPUT=${CONFIG_PROV}

# Mark successful completion
touch "${SHARED_DIR}/provision-complete"
