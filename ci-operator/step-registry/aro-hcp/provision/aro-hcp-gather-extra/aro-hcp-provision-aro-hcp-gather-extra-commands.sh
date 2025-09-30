#!/bin/bash
# Gather information about deployment operations in the resource group before teardown
set -o errexit
set -o nounset
set -o pipefail

# use login script from the aro-hcp-provision-azure-login step
"${SHARED_DIR}/az-login.sh"

ls -al "${SHARED_DIR}"/
for file in "${SHARED_DIR}"/tracked-resource-group_*; do
    if [ -f "$file" ]; then
        full_filename=$(basename "$file")
        resource_group_name=${full_filename#tracked-resource-group_}
        mkdir "${ARTIFACT_DIR}/${resource_group_name}"

        az deployment group list --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" -o yaml > "${ARTIFACT_DIR}/${resource_group_name}/deployment-group-list.yaml" || true

        # List all deployments in the specified resource group and extract their names
        deployment_names=$(az deployment group list --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" --query "[].name" -o tsv || true)

        # Check if any deployments were found
        if [ -z "$deployment_names" ]; then
            echo "No deployments found in resource group: ${resource_group_name}"
            exit 0
        fi

        echo "Deployment operations for resource group: ${resource_group_name}"
        echo "--------------------------------------------------------"

        # Loop through each deployment name and list its operations
        for deployment_name in $deployment_names; do
            az deployment operation group list --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" --name "$deployment_name" -o yaml > "${ARTIFACT_DIR}/${resource_group_name}/deployment-operation-${deployment_name}.yaml" || true

            echo "Deployment: $deployment_name"
            az deployment operation group list --subscription "${SUBSCRIPTION}" --resource-group "${resource_group_name}" --name "$deployment_name" -o table || true
            echo "--------------------------------------------------------"
        done
    fi
done
