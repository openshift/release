#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"

# iterate over every tracked resource group
mount
ls -al "${SHARED_DIR}"
ls -al "${SHARED_DIR}"/tracked-resource-groups
for file in "${SHARED_DIR}"/tracked-resource-groups/*; do
    if [ -f "$file" ]; then
        resource_group_name=$(basename "$file")

        # Delete each resource group
        az resource delete --resource-group "${resource_group_name}" --name "${CLUSTER_NAME}" --resource-type "Microsoft.RedHatOpenShift/hcpOpenShiftClusters" || true
    fi
done

