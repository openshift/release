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

# Parse CI image ref into registry/repository/digest components
# CI images come as: registry.ci.openshift.org/ci-op-xxx/pipeline@sha256:abc...
MGMT_AGENT_DIGEST=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f2)
MGMT_AGENT_REPOSITORY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
MGMT_AGENT_SOURCE_REGISTRY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)
echo "source registry set to ${MGMT_AGENT_SOURCE_REGISTRY} and repo ${MGMT_AGENT_REPOSITORY} for Mgmt Agent Image"

# Set up registries that require oc login for ImageMirror to pull from CI registry
if [[ -n "${USE_OC_LOGIN_REGISTRIES}" ]]; then
    USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${MGMT_AGENT_SOURCE_REGISTRY}"
else
    USE_OC_LOGIN_REGISTRIES="${MGMT_AGENT_SOURCE_REGISTRY}"
fi
echo "USE_OC_LOGIN_REGISTRIES set to: ${USE_OC_LOGIN_REGISTRIES}"
export USE_OC_LOGIN_REGISTRIES

# Build override config with CI image coordinates
OVERRIDE_CONFIG_FILE="/tmp/cd-mgmt-override-config-$(date +%s).yaml"
export OVERRIDE_CONFIG_FILE

yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.registry = \"${MGMT_AGENT_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.repository = \"${MGMT_AGENT_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.digest = \"${MGMT_AGENT_DIGEST}\"
" > "${OVERRIDE_CONFIG_FILE}"
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

cd dev-infrastructure && make mgmt.aks.kubeconfig && cd ..

# Deploy mgmt-agent with CI image override via the pipeline/ target
# (pipeline/ goes through local-run which supports --config-file-override)
make "pipeline/MgmtAgent" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}"

# Deploy remaining MGMT services without overrides (they use upstream images)
make secret-sync-controller.deploy_pipeline
make acm.deploy_pipeline
make hypershiftoperator.deploy_pipeline
make maestro.agent.deploy_pipeline
make observability.tracing.deploy_pipeline
