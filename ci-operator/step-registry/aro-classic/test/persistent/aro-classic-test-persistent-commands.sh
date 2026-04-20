#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export AZURE_SUBSCRIPTION_ID; AZURE_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

AZURE_FP_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/fp-client-id")
export AZURE_FP_SERVICE_PRINCIPAL_ID; AZURE_FP_SERVICE_PRINCIPAL_ID=$(az ad sp show --id "${AZURE_FP_CLIENT_ID}" --query "id" -o tsv)

export LOCATION; LOCATION="${LOCATION:=${LEASED_RESOURCE}}"
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_LOCATION:-}" ]]; then
  LOCATION="${MULTISTAGE_PARAM_OVERRIDE_LOCATION}"
fi
export E2E_TYPE; E2E_TYPE="${E2E_TYPE:=csp}"
export RESOURCEGROUP; RESOURCEGROUP="${NAMESPACE}-prow-${LOCATION}-${UNIQUE_HASH}-${E2E_TYPE}"
export CLUSTER; CLUSTER="${RESOURCEGROUP}"


echo "Location: ${LOCATION}"
echo "Resource Group: ${RESOURCEGROUP}"
echo "Cluster Name: ${CLUSTER}"

e2e.test -test.v --ginkgo.v --ginkgo.timeout 180m --ginkgo.flake-attempts=2 --ginkgo.no-color --ginkgo.label-filter=!smoke