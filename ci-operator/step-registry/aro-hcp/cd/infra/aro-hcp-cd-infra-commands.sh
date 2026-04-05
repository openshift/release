#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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

export DEPLOY_ENV="${DEPLOY_ENV:-cspr}"
export SKIP_CONFIRM=true
export PERSIST=true
export PRINCIPAL_ID; PRINCIPAL_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)

cd dev-infrastructure
make region
make svc

make svc.aks.admin-access
make svc.cs-pr-check-msi
make mgmt
make mgmt.aks.admin-access
make monitoring
