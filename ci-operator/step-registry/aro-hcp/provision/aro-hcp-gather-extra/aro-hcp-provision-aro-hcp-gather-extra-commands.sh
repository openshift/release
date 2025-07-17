#!/bin/bash
# Gather information about deployment operations in the resource group before teardown
set -o errexit
set -o nounset
set -o pipefail

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"

ls -al "${SHARED_DIR}"/
for file in "${SHARED_DIR}"/tracked-resource-group_*; do
    if [ -f "$file" ]; then
        full_filename=$(basename "$file")
        resource_group_name=${full_filename#tracked-resource-group_}
        mkdir "${ARTIFACT_DIR}/${resource_group_name}"

        az deployment group list --resource-group "${resource_group_name}" -o yaml > "${ARTIFACT_DIR}/${resource_group_name}/deployment-group-list.yaml"

        # List all deployments in the specified resource group and extract their names
        deployment_names=$(az deployment group list --resource-group "${resource_group_name}" --query "[].name" -o tsv)

        # Check if any deployments were found
        if [ -z "$deployment_names" ]; then
            echo "No deployments found in resource group: ${resource_group_name}"
            exit 0
        fi

        echo "Deployment operations for resource group: ${resource_group_name}"
        echo "--------------------------------------------------------"

        # Loop through each deployment name and list its operations
        for deployment_name in $deployment_names; do
            az deployment operation group list --resource-group "${resource_group_name}" --name "$deployment_name" -o yaml > "${ARTIFACT_DIR}/${resource_group_name}/deployment-operation-${deployment_name}.yaml"

            echo "Deployment: $deployment_name"
            az deployment operation group list --resource-group "${resource_group_name}" --name "$deployment_name" -o table
            echo "--------------------------------------------------------"
        done
    fi
done


