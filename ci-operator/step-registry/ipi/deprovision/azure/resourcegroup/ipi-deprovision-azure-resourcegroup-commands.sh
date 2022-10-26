#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

existing_rg=$(yq-go r "${CONFIG}" 'platform.azure.resourceGroupName')
cloud_name=$(yq-go r "${CONFIG}" 'platform.azure.cloudName')

# az should already be there
command -v az

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"

if [ "$cloud_name" == "AzureStackCloud" ]; then
    AZURE_AUTH_LOCATION="${SHARED_DIR}/osServicePrincipal.json"

	AZURESTACK_ENDPOINT=$(cat ${SHARED_DIR}/AZURESTACK_ENDPOINT)
	SUFFIX_ENDPOINT=$(cat ${SHARED_DIR}/SUFFIX_ENDPOINT)

	az cloud register \
		-n PPE \
		--endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
		--suffix-storage-endpoint "${SUFFIX_ENDPOINT}" 
	az cloud set -n PPE
	az cloud update --profile 2019-03-01-hybrid
fi

AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

# delete resource group in case it still exists
echo "Deleting resource group: ${existing_rg}"
if [ "$(az group exists -n "${existing_rg}")" == "true" ]
then
	az group delete -y -n "${existing_rg}"
fi
