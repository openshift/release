#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_SUBSCRIPTION_ID; AZURE_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-subscription-id")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
az bicep install

export DEPLOY_ENV="${DEPLOY_ENV:-cspr}"
export SKIP_CONFIRM=true
export PERSIST=true
export DETECT_DIRTY_GIT_WORKTREE=0
export AZURE_TOKEN_CREDENTIALS="${AZURE_TOKEN_CREDENTIALS:-dev}"

# Parse CI image refs into registry/repository/digest components
# CI images come as: registry.ci.openshift.org/ci-op-xxx/pipeline@sha256:abc...
BACKEND_DIGEST=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f2)
BACKEND_REPOSITORY=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
BACKEND_SOURCE_REGISTRY=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${BACKEND_SOURCE_REGISTRY} and repo ${BACKEND_REPOSITORY} for Backend Image"

FRONTEND_DIGEST=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f2)
FRONTEND_REPOSITORY=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
FRONTEND_SOURCE_REGISTRY=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${FRONTEND_SOURCE_REGISTRY} and repo ${FRONTEND_REPOSITORY} for Frontend Image"

ADMIN_API_DIGEST=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f2)
ADMIN_API_REPOSITORY=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
ADMIN_API_SOURCE_REGISTRY=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${ADMIN_API_SOURCE_REGISTRY} and repo ${ADMIN_API_REPOSITORY} for Admin API Image"

SESSIONGATE_DIGEST=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f2)
SESSIONGATE_REPOSITORY=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
SESSIONGATE_SOURCE_REGISTRY=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${SESSIONGATE_SOURCE_REGISTRY} and repo ${SESSIONGATE_REPOSITORY} for SessionGate Image"

MGMT_AGENT_DIGEST=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f2)
MGMT_AGENT_REPOSITORY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
MGMT_AGENT_SOURCE_REGISTRY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${MGMT_AGENT_SOURCE_REGISTRY} and repo ${MGMT_AGENT_REPOSITORY} for Mgmt Agent Image"

KUBE_APPLIER_DIGEST=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f2)
KUBE_APPLIER_REPOSITORY=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
KUBE_APPLIER_SOURCE_REGISTRY=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${KUBE_APPLIER_SOURCE_REGISTRY} and repo ${KUBE_APPLIER_REPOSITORY} for Kube Applier Image"

# Set up registries that require oc login for ImageMirror to pull from CI registry
if [[ -n "${USE_OC_LOGIN_REGISTRIES}" ]]; then
    USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${MGMT_AGENT_SOURCE_REGISTRY} ${KUBE_APPLIER_SOURCE_REGISTRY}"
else
    USE_OC_LOGIN_REGISTRIES="${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${MGMT_AGENT_SOURCE_REGISTRY} ${KUBE_APPLIER_SOURCE_REGISTRY}"
fi
echo "USE_OC_LOGIN_REGISTRIES set to: ${USE_OC_LOGIN_REGISTRIES}"
export USE_OC_LOGIN_REGISTRIES

# Build override config with CI image coordinates
# ImageMirror in each service's pipeline.yaml will copy from CI registry to ACR
OVERRIDE_CONFIG_FILE="/tmp/cd-svc-override-config-$(date +%s).yaml"
export OVERRIDE_CONFIG_FILE

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
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.registry = \"${MGMT_AGENT_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.repository = \"${MGMT_AGENT_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.digest = \"${MGMT_AGENT_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.registry = \"${KUBE_APPLIER_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.repository = \"${KUBE_APPLIER_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.digest = \"${KUBE_APPLIER_DIGEST}\"
" > "${OVERRIDE_CONFIG_FILE}"
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

cd dev-infrastructure && make svc.aks.kubeconfig && cd ..

# Deploy services using CI image override (ImageMirror copies from CI registry to ACR)
make "pipeline/RP.Backend" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}"
make "pipeline/RP.Frontend" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}"
make "pipeline/AdminAPI" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}"
make "pipeline/SessionGate" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}"

# Non-image services (no override needed)
make maestro.server.deploy_pipeline
make observability.tracing.deploy_pipeline

# CSPR dressup: creates CS namespace with MSI/KV bindings, deploys cleaners
./svc-deploy.sh "${DEPLOY_ENV}" cluster-service svc deploy-pr-env-deps
