#!/bin/bash

set -e
set -u
set -o nounset
set -o errexit
set -o pipefail
set -x

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_SA_NAME=${AZURE_SA_NAME:=""}
AZURE_SA_CONTAINER=${AZURE_SA_CONTAINER:=""}
ARO_CLUSTER_FILES=${ARO_CLUSTER_FILES:=""}

echo "Logging into Azure Cloud"
# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

for f in $ARO_CLUSTER_FILES; do
  az storage blob download --account-name ${AZURE_SA_NAME} --container-name ${AZURE_SA_CONTAINER} --name ${f} --file ${SHARED_DIR}/${f} --auth-mode login
done