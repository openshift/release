#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

RESOURCE_GROUP=$(cat "${SHARED_DIR}/RESOURCE_GROUP_NAME")

# Login using the shared dir scripts created in the ipi-conf-azurestack-commands.sh
chmod +x "${SHARED_DIR}/azurestack-login-script.sh"
source ${SHARED_DIR}/azurestack-login-script.sh

# The preceding ipi-deprovision chain runs `openshift-install destroy cluster`,
# which already removes the resource group when install-config pins
# platform.azure.resourceGroupName to it. Only delete what is still there so
# this step stays idempotent instead of failing on ResourceGroupNotFound.
if [[ "$(az group exists --resource-group "$RESOURCE_GROUP")" == "true" ]]; then
  az group delete --resource-group "$RESOURCE_GROUP" -y
  echo "Deleted successfully!"
else
  echo "Resource group $RESOURCE_GROUP no longer exists, nothing to delete."
fi