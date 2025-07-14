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
for file in "${SHARED_DIR}"/tracked-resource-group_*; do
    if [ -f "$file" ]; then
        full_filename=$(basename "$file")
        resource_group_name=${full_filename#tracked-resource-group_}

        # Get list of hcp clusters in the resource group
        clusters=$(az resource list --resource-group "${resource_group_name}" --resource-type "Microsoft.RedHatOpenShift/hcpOpenShiftClusters" --query "[].name" -o tsv)

        # Delete each hcp cluster found in the resource group
        if [ -n "$clusters" ]; then
          while IFS= read -r cluster_name; do
            az resource delete --resource-group "${resource_group_name}" --name "${cluster_name}" --resource-type "Microsoft.RedHatOpenShift/hcpOpenShiftClusters"  || true
          done <<< "$clusters"
        fi
    fi
done

