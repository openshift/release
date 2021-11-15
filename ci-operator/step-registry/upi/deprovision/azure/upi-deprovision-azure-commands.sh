#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

AZURE_AUTH_TENANT_ID=$(cat ${SHARED_DIR}/AZURE_AUTH_TENANT_ID)
AZURE_AUTH_CLIENT_ID=$(cat ${SHARED_DIR}/AZURE_AUTH_CLIENT_ID)
AZURE_AUTH_CLIENT_SECRET=$(cat ${SHARED_DIR}/AZURE_AUTH_CLIENT_SECRET)

RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP_NAME")

az login --service-principal -u $AZURE_AUTH_CLIENT_ID -p $AZURE_AUTH_CLIENT_SECRET --tenant $AZURE_AUTH_TENANT_ID > /dev/null

az group delete --help
az group delete --resource-group $RESOURCE_GROUP -y
echo "Deleted successfully!"
