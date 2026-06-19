#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${ARO_HCP_SUITE_NAME:?ARO_HCP_SUITE_NAME must be set}"

# upgrade/create writes; upgrade/post-infra reads. SHARED_DIR persists across workflow steps.
export SETUP_FILEPATH="${SETUP_FILEPATH:-${SHARED_DIR}/e2e-setup.json}"

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

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

unset GOFLAGS

# This block prepares the environment to run the tests in.
# It runs against INFRA_SUBSCRIPTION.
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV="${DEPLOY_ENV}"
export KUBECONFIG=kubeconfig
export AZURE_TOKEN_CREDENTIALS=prod
FRONTEND_ADDRESS="https://$(kubectl get virtualservice -n aro-hcp aro-hcp-vs-frontend -o jsonpath='{.spec.hosts[0]}')"
make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

# This block runs the tests against CUSTOMER_SUBSCRIPTION.
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
make e2e-local/setup FRONTEND_ADDRESS="${FRONTEND_ADDRESS}"

./test/aro-hcp-tests run-suite "${ARO_HCP_SUITE_NAME}" \
  --junit-path="${ARTIFACT_DIR}/junit.xml" \
  --html-path="${ARTIFACT_DIR}/extension-test-result-summary.html" \
  --max-concurrency 100

junit_shared_name="${E2E_JUNIT_SHARED_NAME:-junit-e2e-suite.xml.gz}"
gzip -c "${ARTIFACT_DIR}/junit.xml" > "${SHARED_DIR}/${junit_shared_name}"
