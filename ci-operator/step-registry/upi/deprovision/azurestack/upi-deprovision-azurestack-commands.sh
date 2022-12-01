#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

TENANT_ID=$(cat ${SHARED_DIR}/TENANT_ID)
APP_ID=$(cat ${SHARED_DIR}/APP_ID)
AAD_CLIENT_SECRET=$(cat ${SHARED_DIR}/AAD_CLIENT_SECRET)

RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP_NAME")

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
${SHARED_DIR}/azurestack-login-script.sh

az group delete --help
az group delete --resource-group $RESOURCE_GROUP -y
echo "Deleted successfully!"