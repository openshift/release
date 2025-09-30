#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# use login script from the aro-hcp-provision-azure-login step
"${SHARED_DIR}/az-login.sh"

# iterate over every tracked resource group
ls -al "${SHARED_DIR}"/
for file in "${SHARED_DIR}"/tracked-resource-group_*; do
    if [ -f "$file" ]; then
        full_filename=$(basename "$file")
        resource_group_name=${full_filename#tracked-resource-group_}

        # Get list of hcp clusters in the resource group
        clusters=$(az resource list --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" --resource-type "Microsoft.RedHatOpenShift/hcpOpenShiftClusters" --query "[].name" -o tsv || true)

        # Delete each hcp cluster found in the resource group
        if [ -n "$clusters" ]; then
          while IFS= read -r cluster_name; do
            az resource delete --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" --name "${cluster_name}" --resource-type "Microsoft.RedHatOpenShift/hcpOpenShiftClusters" || true
          done <<< "$clusters"
        fi
    fi
done
