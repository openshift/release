#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${ARO_HCP_SUITE_NAME:?ARO_HCP_SUITE_NAME must be set}"

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

if ! yq -e ".clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift" config/config.yaml >/dev/null; then
  echo "ERROR: hypershift defaults missing in config/config.yaml for DEPLOY_ENV=${DEPLOY_ENV}" >&2
  exit 1
fi

export OVERRIDE_CONFIG_FILE="${SHARED_DIR}/config-override-upgrade.yaml"

yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift = (
    load(\"config/config.yaml\") | .clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift
  )
" > "${OVERRIDE_CONFIG_FILE}"

cp "${OVERRIDE_CONFIG_FILE}" "${SHARED_DIR}/config-override.yaml"

echo "Hypershift operator image (in override, sourced from PR-head config/config.yaml):"
yq ".clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.image" "${OVERRIDE_CONFIG_FILE}"
echo "Hypershift shared ingress image (in override, sourced from PR-head config/config.yaml):"
yq ".clouds.dev.environments.${DEPLOY_ENV}.defaults.hypershift.sharedIngressImage" "${OVERRIDE_CONFIG_FILE}"

unset GOFLAGS

# Prepare svc cluster access for the test harness (customer tests run below).
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

# HypershiftOperator runs on the management cluster; upgrade/in-place invokes
# make pipeline/RP.HypershiftOperator and requires mgmt kubeconfig in KUBECONFIG.
make -C dev-infrastructure/ mgmt.aks.kubeconfig MGMT_KUBECONFIG_FILE=../mgmt-kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=mgmt-kubeconfig

az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

# Single suite: create cluster, run pipeline/RP.HypershiftOperator, hash watch, cleanup.
./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" \
  --junit-path="${ARTIFACT_DIR}/junit.xml" \
  --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" \
  --max-concurrency 100

gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/junit-e2e-upgrade.xml.gz"
