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

cmd="./test/aro-hcp-tests cleanup resource-groups --expired"

if [ -n "${CLEANUP_MODE}" ]; then
  cmd="${cmd} --mode ${CLEANUP_MODE}"
fi

if [ -n "${INCLUDE_LOCATION}" ]; then
  cmd="${cmd} --include-location ${INCLUDE_LOCATION}"
fi

if [ -n "${EXCLUDE_LOCATION}" ]; then
  cmd="${cmd} --exclude-location ${EXCLUDE_LOCATION}"
fi

echo "Running: ${cmd}"
eval "${cmd}"
