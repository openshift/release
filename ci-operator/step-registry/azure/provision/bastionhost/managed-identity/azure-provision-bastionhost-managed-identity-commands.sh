#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

command -v az
az --version
# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_name="${CLUSTER_NAME}-bastion"

if [ -z "${RESOURCE_GROUP}" ]; then
  rg_file="${SHARED_DIR}/resourcegroup"
  if [ -f "${rg_file}" ]; then
    bastion_rg=$(cat "${rg_file}")
  else
    echo "Did not find ${rg_file}!"
    exit 1
  fi
else
  bastion_rg="${RESOURCE_GROUP}"
fi

command -v az
az --version

azure_role_assignment_file="${SHARED_DIR}/azure_role_assignment_ids"
azure_identity_auth_file="${SHARED_DIR}/azure_managed_identity_osServicePrincipal.json"
if [[ "${AZURE_MANAGED_IDENTITY_TYPE}" == "user-defined" ]]; then
    # create user-defined managed identity
    echo "Enable user-defined managed identity on bastion vm"
    user_identity_name="${CLUSTER_NAME}-identity"
    run_command "az identity create -g ${bastion_rg} -n ${user_identity_name}"

    # enable user-defined managed identity on bastion vm
    run_command "az vm identity assign --identities ${user_identity_name} -g ${bastion_rg} -n ${bastion_name}"

    # assign role
    echo "Assign role 'Contributor' 'User Access Administrator' 'Storage Blob Data Contributor' to the identity"
    user_identity_id=$(az identity show -g ${bastion_rg} -n ${user_identity_name} --query 'principalId' -otsv)
    run_command "az role assignment create --role 'Contributor' --assignee ${user_identity_id} --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    run_command "az role assignment create --role 'User Access Administrator' --assignee ${user_identity_id} --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    # 4.16 OCPBUGS-38821, 4.18 OCPBUGS-37587
    # additonal permission is required when allowSharedKeyAccess of storage account is disabled and switching to use Azure AD for authentication
    run_command "az role assignment create --role 'Storage Blob Data Contributor' --assignee ${user_identity_id} --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    # save role assignment id for destroy
    az role assignment list --assignee ${user_identity_id} --query '[].id' -otsv >> ${azure_role_assignment_file}
    

    # save azure auth json file
    user_identity_clientid=$(az vm identity show -g "${bastion_rg}" -n "${bastion_name}" --query "userAssignedIdentities.\"/subscriptions/${AZURE_AUTH_SUBSCRIPTION}/resourceGroups/${bastion_rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/${user_identity_name}\".clientId" -otsv)
    cat > "${azure_identity_auth_file}" << EOF
{"subscriptionId":"${AZURE_AUTH_SUBSCRIPTION}","clientId":"${user_identity_clientid}","tenantId":"${AZURE_AUTH_TENANT_ID}"}
EOF
    
elif [[ "${AZURE_MANAGED_IDENTITY_TYPE}" == "system" ]]; then
    # enable system managed identity on bastion
    # assign "Contributor" and "User Access Administrator role" to identity
    echo "Enable system managed identity on bastion vm, and assign role 'Contributor' 'User Access Administrator' 'Storage Blob Data Contributor' to the identity"
    run_command "az vm identity assign -g ${bastion_rg} -n ${bastion_name} --role Contributor --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    system_identity_id=$(az vm identity show -g "${bastion_rg}" -n "${bastion_name}" --query 'principalId' -otsv)
    run_command "az role assignment create --role 'User Access Administrator' --assignee ${system_identity_id} --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    # 4.16 OCPBUGS-38821, 4.18 OCPBUGS-37587
    # additonal permission is required when allowSharedKeyAccess of storage account is disabled and switching to use Azure AD for authentication
    run_command "az role assignment create --role 'Storage Blob Data Contributor' --assignee ${system_identity_id} --scope /subscriptions/${AZURE_AUTH_SUBSCRIPTION}"
    # save role assignment id for destroy
    az role assignment list --assignee ${system_identity_id} --query '[].id' -otsv >> ${azure_role_assignment_file}

    # save azure auth json file
    cat > "${azure_identity_auth_file}" << EOF
{"subscriptionId":"${AZURE_AUTH_SUBSCRIPTION}","tenantId":"${AZURE_AUTH_TENANT_ID}"}
EOF
else
    echo "ERROR: unsupported azure managed identity type ${AZURE_MANAGED_IDENTITY_TYPE}!"
    exit 1
fi

exit 0

