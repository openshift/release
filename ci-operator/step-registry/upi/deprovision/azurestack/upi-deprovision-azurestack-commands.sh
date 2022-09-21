#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

TENANT_ID=$(cat ${SHARED_DIR}/TENANT_ID)
APP_ID=$(cat ${SHARED_DIR}/APP_ID)
AAD_CLIENT_SECRET=$(cat ${SHARED_DIR}/AAD_CLIENT_SECRET)

AZURESTACK_ENDPOINT=$(cat ${SHARED_DIR}/AZURESTACK_ENDPOINT)
SUFFIX_ENDPOINT=$(cat ${SHARED_DIR}/SUFFIX_ENDPOINT)
RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP_NAME")

az cloud register \
    -n PPE \
    --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
    --suffix-storage-endpoint "${SUFFIX_ENDPOINT}" 
az cloud set -n PPE
az cloud update --profile 2019-03-01-hybrid
az login --service-principal -u $APP_ID -p $AAD_CLIENT_SECRET --tenant $TENANT_ID > /dev/null

az group delete --help
az group delete --resource-group $RESOURCE_GROUP -y
echo "Deleted successfully!"