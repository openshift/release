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
: "${EXPORTER_IMAGE:?EXPORTER_IMAGE must be set}"

if [[ ! -f "${SHARED_DIR}/config.yaml" ]]; then
  echo "ERROR: ${SHARED_DIR}/config.yaml missing; run aro-hcp-provision-from-main first"
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
: "${CUSTOMER_SUBSCRIPTION:?CUSTOMER_SUBSCRIPTION must be provided by the runtime slot export file}"

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

# Preserve the Hypershift images from the PR config when the shared helper
# builds the regional service image override.
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

export _YQ_HO_REGISTRY; _YQ_HO_REGISTRY=$(yq '.defaults.hypershift.image.registry' config/config.yaml)
export _YQ_HO_REPOSITORY; _YQ_HO_REPOSITORY=$(yq '.defaults.hypershift.image.repository' config/config.yaml)
export _YQ_HO_DIGEST; _YQ_HO_DIGEST=$(yq '.defaults.hypershift.image.digest' config/config.yaml)
export _YQ_SHARED_INGRESS_REGISTRY; _YQ_SHARED_INGRESS_REGISTRY=$(yq '.defaults.hypershift.sharedIngressImage.registry' config/config.yaml)
export _YQ_SHARED_INGRESS_REPOSITORY; _YQ_SHARED_INGRESS_REPOSITORY=$(yq '.defaults.hypershift.sharedIngressImage.repository' config/config.yaml)
export _YQ_SHARED_INGRESS_DIGEST; _YQ_SHARED_INGRESS_DIGEST=$(yq '.defaults.hypershift.sharedIngressImage.digest' config/config.yaml)

yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.registry = strenv(_YQ_HO_REGISTRY) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.repository = strenv(_YQ_HO_REPOSITORY) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image.digest = strenv(_YQ_HO_DIGEST) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.registry = strenv(_YQ_SHARED_INGRESS_REGISTRY) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.repository = strenv(_YQ_SHARED_INGRESS_REPOSITORY) |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage.digest = strenv(_YQ_SHARED_INGRESS_DIGEST)
" > "${SHARED_DIR}/hypershift-image-overrides.yaml"

unset _YQ_HO_REGISTRY _YQ_HO_REPOSITORY _YQ_HO_DIGEST
unset _YQ_SHARED_INGRESS_REGISTRY _YQ_SHARED_INGRESS_REPOSITORY _YQ_SHARED_INGRESS_DIGEST

# shellcheck source=hack/ci/build-config-override.sh
source hack/ci/build-config-override.sh

cp "${OVERRIDE_CONFIG_FILE}" "${SHARED_DIR}/config-override-upgrade.yaml"
export OVERRIDE_CONFIG_FILE="${SHARED_DIR}/config-override-upgrade.yaml"

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
CUSTOMER_SUBSCRIPTION="$(az account show --output tsv --query 'name')"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

SKIP_CERT_VERIFICATION=true \
FRONTEND_ADDRESS="${FRONTEND_ADDRESS}" \
CUSTOMER_SUBSCRIPTION="${CUSTOMER_SUBSCRIPTION}" \
  ./test/aro-hcp-tests run-suite upgrade/in-place \
  --junit-path="${ARTIFACT_DIR}/junit.xml" \
  --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" \
  --max-concurrency 100

gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e-upgrade.xml.gz"
