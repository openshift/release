#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

# The following environment variables are provided in the original source, but not yet here:
# "AZURE_CLOUD_NAME=${AZURE_CLOUD_NAME}" \
# "AZURE_ENVIRONMENT=${AZURE_ENVIRONMENT}" \
# "AZURE_FP_CLIENT_ID=${AZURE_FP_CLIENT_ID}" \
# "AZURE_FP_SERVICE_PRINCIPAL_ID=${AZURE_FP_SERVICE_PRINCIPAL_ID}" \
# "AZURE_SUBSCRIPTION_ID=${AZURE_SUBSCRIPTION_ID}" \
# "LOCATION=${RP_LOCATION}" \
# "MDM_E2E_ACCOUNT=${MDM_E2E_ACCOUNT}" \
# "MDM_E2E_NAMESPACE=${MDM_E2E_NAMESPACE}" \
# "RESOURCEGROUP=${E2E_RG_NAME}" \
# "CLUSTER=${E2E_RG_NAME}" \
# "OS_CLUSTER_VERSION=${OS_CLUSTER_VERSION}" \
# "MASTER_VM_SIZE=${MASTER_VM_SIZE}" \
# "WORKER_VM_SIZE=${WORKER_VM_SIZE}" \
# "USE_WI=${USE_WI}" \
# "PLATFORM_WORKLOAD_IDENTITY_ROLE_SETS=${PLATFORM_WORKLOAD_IDENTITY_ROLE_SETS}" \
# "E2E_TYPE=${E2E_TYPE}" \
# "RUN_TIMESTAMP=${RUN_TIMESTAMP}" \
# ref: https://msazure.visualstudio.com/AzureRedHatOpenShift/_git/ARO-Pipelines?path=/e2e/bin/%7BCLOUDENV%7D.%7BDEPLOYENV%7D.%7BREGION%7D.e2e.sh

e2e.test -test.v --ginkgo.v --ginkgo.timeout 180m --ginkgo.flake-attempts=2 --ginkgo.no-color --ginkgo.label-filter=${E2E_LABEL_FILTER}