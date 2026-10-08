#!/bin/bash
set -euo pipefail

RESOURCE_GROUP=""

cleanup() {
  local rc=$?
  set +e
  if [[ -n "${RESOURCE_GROUP}" ]]; then
    echo "Cleaning up resource group ${RESOURCE_GROUP}"
    az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
  fi
  exit "${rc}"
}
trap cleanup EXIT

echo "az version:"
az version

if az account show --output none 2>/dev/null; then
  echo "Already logged in to Azure"
else
  echo "Not logged in to Azure; looking for credentials in probable locations"
  CRED_FILE=""
  for candidate in \
    "${AZURE_AUTH_LOCATION:-}" \
    "${CLUSTER_PROFILE_DIR:-}/osServicePrincipal.json" \
    "${SHARED_DIR:-}/azure-sp-contributor.json" \
    "${SHARED_DIR:-}/azure_minimal_permission"; do
    if [[ -n "${candidate}" && -f "${candidate}" ]]; then
      CRED_FILE="${candidate}"
      echo "Found credentials at ${CRED_FILE}"
      break
    fi
  done

  if [[ -z "${CRED_FILE}" ]]; then
    echo "No Azure credentials found in any probable location" >&2
    exit 1
  fi

  AZURE_AUTH_CLIENT_ID=$(jq -r .clientId "${CRED_FILE}")
  AZURE_AUTH_TENANT_ID=$(jq -r .tenantId "${CRED_FILE}")

  # Disable tracing while the client secret is in scope
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  az login --service-principal \
    -u "${AZURE_AUTH_CLIENT_ID}" \
    -p "$(jq -r .clientSecret "${CRED_FILE}")" \
    --tenant "${AZURE_AUTH_TENANT_ID}" \
    --output none
  ${WAS_TRACING} && set -x

  echo "Logged in with service principal ${AZURE_AUTH_CLIENT_ID}"
fi

AZURE_SUBSCRIPTION_ID=$(az account show --query id --output tsv)
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
echo "Using subscription ${AZURE_SUBSCRIPTION_ID}"

echo "Existing storage accounts in subscription:"
az storage account list --output table

echo "Existing managed VM images in subscription:"
az image list --output table

echo "Existing Shared Image Gallery image definitions in subscription:"
az sig list --query "[].{name:name,resourceGroup:resourceGroup}" --output json | jq -c '.[]' | while read -r gallery; do
  gallery_name=$(jq -r .name <<<"${gallery}")
  gallery_rg=$(jq -r .resourceGroup <<<"${gallery}")
  echo "Gallery ${gallery_name} (${gallery_rg}):"
  az sig image-definition list --gallery-name "${gallery_name}" --resource-group "${gallery_rg}" --output table
done

TEST_ID="ci-${PULL_NUMBER:+${PULL_NUMBER}-}$(uuidgen | cut -d- -f1)"
RESOURCE_GROUP="${TEST_ID}-rg"
STORAGE_ACCOUNT=$(echo "${TEST_ID}sa" | tr -cd '[:alnum:]' | cut -c1-24)

echo "Creating resource group ${RESOURCE_GROUP} in ${AZURE_REGION}"
az group create --name "${RESOURCE_GROUP}" --location "${AZURE_REGION}" --output none

echo "Creating storage account ${STORAGE_ACCOUNT}"
az storage account create \
  --resource-group "${RESOURCE_GROUP}" \
  --location "${AZURE_REGION}" \
  --name "${STORAGE_ACCOUNT}" \
  --kind StorageV2 \
  --sku Standard_LRS \
  --output none

STORAGE_KEY=$(az storage account keys list --resource-group "${RESOURCE_GROUP}" --account-name "${STORAGE_ACCOUNT}" --query "[0].value" --output tsv)

echo "Creating container and uploading test blob"
az storage container create --name test --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" --output none

echo "azure access check $(date -u --rfc-3339=seconds)" > /tmp/test-blob.txt
az storage blob upload \
  --account-name "${STORAGE_ACCOUNT}" \
  --account-key "${STORAGE_KEY}" \
  --container-name test \
  --file /tmp/test-blob.txt \
  --name test-blob.txt \
  --output none

if [[ "$(az storage blob exists --account-name "${STORAGE_ACCOUNT}" --account-key "${STORAGE_KEY}" --container-name test --name test-blob.txt --query exists --output tsv)" != "true" ]]; then
  echo "Uploaded blob not found in storage account" >&2
  exit 1
fi

echo "Successfully uploaded test blob to storage account ${STORAGE_ACCOUNT}"
