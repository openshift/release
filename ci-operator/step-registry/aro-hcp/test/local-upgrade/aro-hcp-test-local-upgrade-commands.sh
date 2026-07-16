#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${BACKEND_IMAGE:?BACKEND_IMAGE must be set}"
: "${FRONTEND_IMAGE:?FRONTEND_IMAGE must be set}"
: "${ADMIN_API_IMAGE:?ADMIN_API_IMAGE must be set}"
: "${SESSIONGATE_IMAGE:?SESSIONGATE_IMAGE must be set}"
: "${HCP_RECOVERY_IMAGE:?HCP_RECOVERY_IMAGE must be set}"
: "${FLEET_IMAGE:?FLEET_IMAGE must be set}"
: "${MGMT_AGENT_IMAGE:?MGMT_AGENT_IMAGE must be set}"
: "${KUBE_APPLIER_IMAGE:?KUBE_APPLIER_IMAGE must be set}"

if [[ ! -f "${SHARED_DIR}/config.yaml" ]]; then
  echo "ERROR: ${SHARED_DIR}/config.yaml missing; run aro-hcp-provision-environment first"
  exit 1
fi

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${env_file}" ]]; then
  printf 'Missing runtime lease export file: %s\n' "${env_file}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${env_file}"

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by SELECTED_LOCATION or the legacy runtime slot export file}"

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"
export AZURE_TOKEN_CREDENTIALS=prod
export SKIP_CONFIRM=true
export PERSIST=true
export DETECT_DIRTY_GIT_WORKTREE=0

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

# Hypershift images from PR config; regional service images from PR pipeline builds.
if ! yq -e '.defaults.hypershift.image.registry' config/config.yaml >/dev/null 2>&1 \
  || ! yq -e '.defaults.hypershift.image.repository' config/config.yaml >/dev/null 2>&1 \
  || ! yq -e '.defaults.hypershift.image.digest' config/config.yaml >/dev/null 2>&1; then
  echo "ERROR: hypershift operator image missing in config/config.yaml (.defaults.hypershift.image)" >&2
  exit 1
fi
if ! yq -e '.defaults.hypershift.sharedIngressImage.registry' config/config.yaml >/dev/null 2>&1 \
  || ! yq -e '.defaults.hypershift.sharedIngressImage.repository' config/config.yaml >/dev/null 2>&1 \
  || ! yq -e '.defaults.hypershift.sharedIngressImage.digest' config/config.yaml >/dev/null 2>&1; then
  echo "ERROR: hypershift sharedIngressImage missing in config/config.yaml (.defaults.hypershift.sharedIngressImage)" >&2
  exit 1
fi

HO_IMAGE_REGISTRY=$(yq '.defaults.hypershift.image.registry' config/config.yaml)
HO_IMAGE_REPOSITORY=$(yq '.defaults.hypershift.image.repository' config/config.yaml)
HO_IMAGE_DIGEST=$(yq '.defaults.hypershift.image.digest' config/config.yaml)
HO_SHARED_INGRESS_REGISTRY=$(yq '.defaults.hypershift.sharedIngressImage.registry' config/config.yaml)
HO_SHARED_INGRESS_REPOSITORY=$(yq '.defaults.hypershift.sharedIngressImage.repository' config/config.yaml)
HO_SHARED_INGRESS_DIGEST=$(yq '.defaults.hypershift.sharedIngressImage.digest' config/config.yaml)

BACKEND_DIGEST=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f2)
BACKEND_REPOSITORY=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
BACKEND_SOURCE_REGISTRY=$(echo "${BACKEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

FRONTEND_DIGEST=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f2)
FRONTEND_REPOSITORY=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
FRONTEND_SOURCE_REGISTRY=$(echo "${FRONTEND_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

ADMIN_API_DIGEST=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f2)
ADMIN_API_REPOSITORY=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
ADMIN_API_SOURCE_REGISTRY=$(echo "${ADMIN_API_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

SESSIONGATE_DIGEST=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f2)
SESSIONGATE_REPOSITORY=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
SESSIONGATE_SOURCE_REGISTRY=$(echo "${SESSIONGATE_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

HCP_RECOVERY_DIGEST=$(echo "${HCP_RECOVERY_IMAGE}" | cut -d'@' -f2)
HCP_RECOVERY_REPOSITORY=$(echo "${HCP_RECOVERY_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
HCP_RECOVERY_SOURCE_REGISTRY=$(echo "${HCP_RECOVERY_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

FLEET_DIGEST=$(echo "${FLEET_IMAGE}" | cut -d'@' -f2)
FLEET_REPOSITORY=$(echo "${FLEET_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
FLEET_SOURCE_REGISTRY=$(echo "${FLEET_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

MGMT_AGENT_DIGEST=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f2)
MGMT_AGENT_REPOSITORY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
MGMT_AGENT_SOURCE_REGISTRY=$(echo "${MGMT_AGENT_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

KUBE_APPLIER_DIGEST=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f2)
KUBE_APPLIER_REPOSITORY=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f2-)
KUBE_APPLIER_SOURCE_REGISTRY=$(echo "${KUBE_APPLIER_IMAGE}" | cut -d'@' -f1 | cut -d '/' -f1)

if [[ -n "${USE_OC_LOGIN_REGISTRIES:-}" ]]; then
  USE_OC_LOGIN_REGISTRIES="${USE_OC_LOGIN_REGISTRIES} ${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${HCP_RECOVERY_SOURCE_REGISTRY} ${FLEET_SOURCE_REGISTRY} ${MGMT_AGENT_SOURCE_REGISTRY} ${KUBE_APPLIER_SOURCE_REGISTRY}"
else
  USE_OC_LOGIN_REGISTRIES="${BACKEND_SOURCE_REGISTRY} ${FRONTEND_SOURCE_REGISTRY} ${ADMIN_API_SOURCE_REGISTRY} ${SESSIONGATE_SOURCE_REGISTRY} ${HCP_RECOVERY_SOURCE_REGISTRY} ${FLEET_SOURCE_REGISTRY} ${MGMT_AGENT_SOURCE_REGISTRY} ${KUBE_APPLIER_SOURCE_REGISTRY}"
fi
export USE_OC_LOGIN_REGISTRIES

export OVERRIDE_CONFIG_FILE="${SHARED_DIR}/config-override-upgrade.yaml"

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
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.registry = \"${HCP_RECOVERY_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.repository = \"${HCP_RECOVERY_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hcpRecovery.image.digest = \"${HCP_RECOVERY_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.registry = \"${FLEET_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.repository = \"${FLEET_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.digest = \"${FLEET_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.registry = \"${MGMT_AGENT_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.repository = \"${MGMT_AGENT_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.digest = \"${MGMT_AGENT_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.registry = \"${KUBE_APPLIER_SOURCE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.repository = \"${KUBE_APPLIER_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.digest = \"${KUBE_APPLIER_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.registry = \"${HO_IMAGE_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.repository = \"${HO_IMAGE_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.digest = \"${HO_IMAGE_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.registry = \"${HO_SHARED_INGRESS_REGISTRY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.repository = \"${HO_SHARED_INGRESS_REPOSITORY}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.digest = \"${HO_SHARED_INGRESS_DIGEST}\"
" > "${OVERRIDE_CONFIG_FILE}"

cp "${OVERRIDE_CONFIG_FILE}" "${SHARED_DIR}/config-override.yaml"

echo "Created upgrade override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

unset GOFLAGS

# Prepare svc cluster access for the test harness (customer tests run below).
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

make -C dev-infrastructure/ mgmt.aks.kubeconfig MGMT_KUBECONFIG_FILE=../mgmt-kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=mgmt-kubeconfig

az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

# UpgradeBarrier needs the spec count so it can wait for all participants before
# electing a runner to execute "make entrypoint/Region".
UPGRADE_SPEC_COUNT=$(./test/aro-hcp-tests list tests --suite upgrade/in-place --output names | grep -c .)
export UPGRADE_SPEC_COUNT

SKIP_CERT_VERIFICATION=true ./test/aro-hcp-tests run-suite upgrade/in-place \
  --junit-path="${ARTIFACT_DIR}/junit.xml" \
  --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" \
  --max-concurrency 100

gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e-upgrade.xml.gz"
