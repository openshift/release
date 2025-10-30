#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"
az bicep install
az bicep version
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
az account show
az config set core.disable_confirm_prompt=true
kubectl version
kubelogin --version
PRINCIPAL_ID=$(az ad sp show --id "${TEST_USER_CLIENT_ID}" --query id -o tsv)
export PRINCIPAL_ID
unset GOFLAGS
make cleanup-entrypoint/Region DEPLOY_ENV=prow CLEANUP_DRY_RUN=false CLEANUP_WAIT=false
make visualize TIMING_OUTPUT=${SHARED_DIR}/steps.yaml VISUALIZATION_OUTPUT=${ARTIFACT_DIR}/timing
cp ${SHARED_DIR}/steps.yaml ${ARTIFACT_DIR}