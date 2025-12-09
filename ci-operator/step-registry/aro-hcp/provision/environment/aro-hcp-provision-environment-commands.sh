#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"
oc version
kubelogin --version
export DEPLOY_ENV="prow"

BACKEND_DIGEST=$(echo ${BACKEND_IMAGE} | cut -d'@' -f2)
BACKEND_REPOSITORY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
BACKEND_SOURCE_REGISTRY=$(echo ${BACKEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${BACKEND_SOURCE_REGISTRY} and repo ${BACKEND_REPOSITORY} for Backend Image"

FRONTEND_DIGEST=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f2)
FRONTEND_REPOSITORY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f2-)
FRONTEND_SOURCE_REGISTRY=$(echo ${FRONTEND_IMAGE} | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${FRONTEND_SOURCE_REGISTRY} and repo ${FRONTEND_REPOSITORY} for Frontend Image"

# Set up registries that require oc login - append backend and frontend registries
if [[ -n "${USE_OC_LOGIN_REGISTRIES}" ]]; then
    USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY}"
else
    USE_OC_LOGIN_REGISTRIES="${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY}"
fi
echo "USE_OC_LOGIN_REGISTRIES set to: ${USE_OC_LOGIN_REGISTRIES}"

export OVERRIDE_CONFIG_FILE=${OVERRIDE_CONFIG_FILE:-/tmp/rp-override-config-$(date +%s).yaml}
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.registry = \"${BACKEND_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.repository = \"${BACKEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.digest = \"${BACKEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.registry = \"${FRONTEND_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.repository = \"${FRONTEND_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.digest = \"${FRONTEND_DIGEST}\"
" > ${OVERRIDE_CONFIG_FILE}
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat ${OVERRIDE_CONFIG_FILE}

unset GOFLAGS
make -o tooling/templatize/templatize entrypoint/Region TIMING_OUTPUT=${SHARED_DIR}/steps.yaml DEPLOY_ENV=prow ENTRYPOINT_JUNIT_OUTPUT=${ARTIFACT_DIR}/junit_entrypoint.xml  
