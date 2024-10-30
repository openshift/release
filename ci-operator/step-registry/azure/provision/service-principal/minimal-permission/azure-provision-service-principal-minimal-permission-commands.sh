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

function run_cmd_with_retries_save_output()
{
    local cmd="$1" output="$2" retries="${3:-}"
    local try=0 ret=0
    [[ -z ${retries} ]] && max="20" || max=${retries}
    echo "Trying ${max} times max to run '${cmd}', save output to ${output}"

    eval "${cmd}" > "${output}" || ret=$?
    while [ X"${ret}" != X"0" ] && [ ${try} -lt ${max} ]; do
        echo "'${cmd}' did not return success, waiting 60 sec....."
        sleep 60
        try=$(( try + 1 ))
        ret=0
        eval "${cmd}" > "${output}" || ret=$?
    done
    if [ ${try} -eq ${max} ]; then
        echo "Never succeed or Timeout"
        return 1
    fi
    echo "Succeed"
    return 0
}

function create_custom_role() {
    local role_definition="$1"
    local custom_role_name="$2"

    # create custom role
    cmd="az role definition create --role-definition ${role_definition}"
    run_command "${cmd}" || return 1

    echo "Sleep 1 min to wait for custom role created"
    sleep 60
}

function create_sp_with_custom_role() {
    local sp_name="$1"
    local custom_role_name="$2"
    local subscription_id="$3"
    local sp_output="$4"

    # create service principal with custom role at the scope of subscription
    # sometimes, failed to create sp as role assignment creation failed, retry
    run_cmd_with_retries_save_output "az ad sp create-for-rbac --role '${custom_role_name}' --name ${sp_name} --scopes /subscriptions/${subscription_id}" "${sp_output}" "5"
}

echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST}"
echo "RELEASE_IMAGE_LATEST_FROM_BUILD_FARM: ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM}"
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"
# After cluster is set up, ci-operator make KUBECONFIG pointing to the installed cluster,
# to make "oc registry login" interact with the build farm, set KUBECONFIG to empty,
# so that the credentials of the build farm registry can be saved in docker client config file.
# A direct connection is required while communicating with build-farm, instead of through proxy
KUBECONFIG="" oc --loglevel=8 registry login
ocp_version=$(oc adm release info ${RELEASE_IMAGE_LATEST_FROM_BUILD_FARM} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "OCP Version: $ocp_version"
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTOIN_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "Installation with minimal permissions is only supported on Azure Public Cloud so far, exit..."
    exit 1
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
ROLE_DEFINITION="${ARTIFACT_DIR}/azure-custom-role-definition-minimal-permissions.json"
CUSTOM_ROLE_NAME="${CLUSTER_NAME}-custom-role"
SP_NAME="${CLUSTER_NAME}-sp"
SP_OUTPUT="$(mktemp)"

required_permissions="""
\"Microsoft.Authorization/policies/audit/action\",
\"Microsoft.Authorization/policies/auditIfNotExists/action\",
\"Microsoft.Authorization/roleAssignments/read\",
\"Microsoft.Authorization/roleAssignments/write\",
\"Microsoft.Compute/availabilitySets/read\",
\"Microsoft.Compute/availabilitySets/write\",
\"Microsoft.Compute/availabilitySets/delete\",
\"Microsoft.Compute/disks/beginGetAccess/action\",
\"Microsoft.Compute/disks/delete\",
\"Microsoft.Compute/disks/read\",
\"Microsoft.Compute/disks/write\",
\"Microsoft.Compute/galleries/images/read\",
\"Microsoft.Compute/galleries/images/versions/read\",
\"Microsoft.Compute/galleries/images/versions/write\",
\"Microsoft.Compute/galleries/images/write\",
\"Microsoft.Compute/galleries/read\",
\"Microsoft.Compute/galleries/write\",
\"Microsoft.Compute/snapshots/read\",
\"Microsoft.Compute/snapshots/write\",
\"Microsoft.Compute/snapshots/delete\",
\"Microsoft.Compute/virtualMachines/delete\",
\"Microsoft.Compute/virtualMachines/powerOff/action\",
\"Microsoft.Compute/virtualMachines/read\",
\"Microsoft.Compute/virtualMachines/write\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/assign/action\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/read\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/write\",
\"Microsoft.Network/dnsZones/A/write\",
\"Microsoft.Network/dnsZones/CNAME/write\",
\"Microsoft.Network/dnszones/CNAME/read\",
\"Microsoft.Network/dnszones/read\",
\"Microsoft.Network/loadBalancers/backendAddressPools/join/action\",
\"Microsoft.Network/loadBalancers/backendAddressPools/read\",
\"Microsoft.Network/loadBalancers/backendAddressPools/write\",
\"Microsoft.Network/loadBalancers/read\",
\"Microsoft.Network/loadBalancers/write\",
\"Microsoft.Network/networkInterfaces/delete\",
\"Microsoft.Network/networkInterfaces/join/action\",
\"Microsoft.Network/networkInterfaces/read\",
\"Microsoft.Network/networkInterfaces/write\",
\"Microsoft.Network/networkSecurityGroups/join/action\",
\"Microsoft.Network/networkSecurityGroups/read\",
\"Microsoft.Network/networkSecurityGroups/securityRules/delete\",
\"Microsoft.Network/networkSecurityGroups/securityRules/read\",
\"Microsoft.Network/networkSecurityGroups/securityRules/write\",
\"Microsoft.Network/networkSecurityGroups/write\",
\"Microsoft.Network/privateDnsZones/A/read\",
\"Microsoft.Network/privateDnsZones/A/write\",
\"Microsoft.Network/privateDnsZones/A/delete\",
\"Microsoft.Network/privateDnsZones/SOA/read\",
\"Microsoft.Network/privateDnsZones/read\",
\"Microsoft.Network/privateDnsZones/virtualNetworkLinks/read\",
\"Microsoft.Network/privateDnsZones/virtualNetworkLinks/write\",
\"Microsoft.Network/privateDnsZones/write\",
\"Microsoft.Network/publicIPAddresses/delete\",
\"Microsoft.Network/publicIPAddresses/join/action\",
\"Microsoft.Network/publicIPAddresses/read\",
\"Microsoft.Network/publicIPAddresses/write\",
\"Microsoft.Network/virtualNetworks/join/action\",
\"Microsoft.Network/virtualNetworks/read\",
\"Microsoft.Network/virtualNetworks/subnets/join/action\",
\"Microsoft.Network/virtualNetworks/subnets/read\",
\"Microsoft.Network/virtualNetworks/subnets/write\",
\"Microsoft.Network/virtualNetworks/write\",
\"Microsoft.Resourcehealth/healthevent/Activated/action\",
\"Microsoft.Resourcehealth/healthevent/InProgress/action\",
\"Microsoft.Resourcehealth/healthevent/Pending/action\",
\"Microsoft.Resourcehealth/healthevent/Resolved/action\",
\"Microsoft.Resourcehealth/healthevent/Updated/action\",
\"Microsoft.Resources/subscriptions/resourceGroups/read\",
\"Microsoft.Resources/subscriptions/resourcegroups/write\",
\"Microsoft.Resources/tags/write\",
\"Microsoft.Storage/storageAccounts/blobServices/read\",
\"Microsoft.Storage/storageAccounts/blobServices/containers/write\",
\"Microsoft.Storage/storageAccounts/fileServices/read\",
\"Microsoft.Storage/storageAccounts/fileServices/shares/read\",
\"Microsoft.Storage/storageAccounts/fileServices/shares/write\",
\"Microsoft.Storage/storageAccounts/fileServices/shares/delete\",
\"Microsoft.Storage/storageAccounts/listKeys/action\",
\"Microsoft.Storage/storageAccounts/read\",
\"Microsoft.Storage/storageAccounts/write\",
\"Microsoft.Authorization/roleAssignments/delete\",
\"Microsoft.Compute/disks/delete\",
\"Microsoft.Compute/galleries/delete\",
\"Microsoft.Compute/galleries/images/delete\",
\"Microsoft.Compute/galleries/images/versions/delete\",
\"Microsoft.Compute/virtualMachines/delete\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/delete\",
\"Microsoft.Network/dnszones/read\",
\"Microsoft.Network/dnsZones/A/read\",
\"Microsoft.Network/dnsZones/A/delete\",
\"Microsoft.Network/dnsZones/CNAME/read\",
\"Microsoft.Network/dnsZones/CNAME/delete\",
\"Microsoft.Network/loadBalancers/delete\",
\"Microsoft.Network/networkInterfaces/delete\",
\"Microsoft.Network/networkSecurityGroups/delete\",
\"Microsoft.Network/privateDnsZones/read\",
\"Microsoft.Network/privateDnsZones/A/read\",
\"Microsoft.Network/privateDnsZones/delete\",
\"Microsoft.Network/privateDnsZones/virtualNetworkLinks/delete\",
\"Microsoft.Network/publicIPAddresses/delete\",
\"Microsoft.Network/virtualNetworks/delete\",
\"Microsoft.Resourcehealth/healthevent/Activated/action\",
\"Microsoft.Resourcehealth/healthevent/Resolved/action\",
\"Microsoft.Resourcehealth/healthevent/Updated/action\",
\"Microsoft.Resources/subscriptions/resourcegroups/delete\",
\"Microsoft.Storage/storageAccounts/delete\",
\"Microsoft.Storage/storageAccounts/listKeys/action\"
"""

# optional permission to gather bootstrap bundle log
required_permissions="""
\"Microsoft.Compute/virtualMachines/retrieveBootDiagnosticsData/action\",
${required_permissions}
"""

# New permissions are instroduced when using CAPZ to provision IPI cluster
if [[ "${CLUSTER_TYPE_MIN_PERMISSOIN}" == "IPI" ]] && (( ocp_minor_version >= 17 && ocp_major_version == 4 )); then
    # routeTables relevant perssions can be removed once OCPBUGS-37663 is fixed.
    required_permissions="""
\"Microsoft.Network/routeTables/read\",
\"Microsoft.Network/routeTables/write\",
\"Microsoft.Network/routeTables/join/action\",
\"Microsoft.Network/loadBalancers/inboundNatRules/read\",
\"Microsoft.Network/loadBalancers/inboundNatRules/write\",
\"Microsoft.Network/loadBalancers/inboundNatRules/join/action\",
\"Microsoft.Network/loadBalancers/inboundNatRules/delete\",
${required_permissions}
"""
fi


if [[ "${CLUSTER_TYPE_MIN_PERMISSOIN}" == "UPI" ]]; then
    required_permissions="""
\"Microsoft.Compute/images/read\",
\"Microsoft.Compute/images/write\",
\"Microsoft.Compute/images/delete\",
\"Microsoft.Compute/virtualMachines/deallocate/action\",
\"Microsoft.Storage/storageAccounts/blobServices/containers/read\",
\"Microsoft.Resources/deployments/read\",
\"Microsoft.Resources/deployments/write\",
\"Microsoft.Resources/deployments/validate/action\",
\"Microsoft.Resources/deployments/operationstatuses/read\",
${required_permissions}
"""
fi

if [[ "${ENABLE_MIN_PERMISSION_FOR_MARKETPLACE}" == "true" ]]; then
    required_permissions="""
\"Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/read\",
\"Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/write\",
\"Microsoft.Compute/images/read\",
\"Microsoft.Compute/images/write\",
\"Microsoft.Compute/images/delete\",
${required_permissions}
"""    
fi

if [[ "${ENABLE_MIN_PERMISSION_FOR_DES}" == "true" ]]; then
    required_permissions="""
\"Microsoft.Compute/diskEncryptionSets/read\",
\"Microsoft.Compute/diskEncryptionSets/write\",
\"Microsoft.Compute/diskEncryptionSets/delete\",
\"Microsoft.KeyVault/vaults/read\",
\"Microsoft.KeyVault/vaults/write\",
\"Microsoft.KeyVault/vaults/delete\",
\"Microsoft.KeyVault/vaults/deploy/action\",
\"Microsoft.KeyVault/vaults/keys/read\",
\"Microsoft.KeyVault/vaults/keys/write\",
${required_permissions}
"""
fi

role_description="the custom role with minimal permissions for cluster ${CLUSTER_NAME}"
assignable_scopes="""
\"/subscriptions/${AZURE_AUTH_SUBSCRIPTOIN_ID}\"
"""

if [[ -n "${AZURE_PERMISSION_FOR_CLUSTER_SP}" ]]; then
    sp_role="${AZURE_PERMISSION_FOR_CLUSTER_SP}"
else
    # create role definition json file
    jq --null-input \
       --arg role_name "${CUSTOM_ROLE_NAME}" \
       --arg description "${role_description}" \
       --argjson assignable_scopes "[ ${assignable_scopes} ]" \
       --argjson permission_list "[ ${required_permissions} ]" '
{
  "Name": $role_name,
  "IsCustom": true,
  "Description": $description,
  "assignableScopes": $assignable_scopes,
  "Actions": $permission_list,
  "notActions": [],
  "dataActions": [],
  "notDataActions": []
}' > "${ROLE_DEFINITION}"

    echo "Creating custom role..."
    create_custom_role "${ROLE_DEFINITION}" "${CUSTOM_ROLE_NAME}"
    # for destroy
    echo "${CUSTOM_ROLE_NAME}" > "${SHARED_DIR}/azure_custom_role_name"
    sp_role="${CUSTOM_ROLE_NAME}"
fi
echo "Creating sp with custom role..."
create_sp_with_custom_role "${SP_NAME}" "${sp_role}" "${AZURE_AUTH_SUBSCRIPTOIN_ID}" "${SP_OUTPUT}"

sp_id=$(jq -r .appId "${SP_OUTPUT}")
sp_password=$(jq -r .password "${SP_OUTPUT}")
sp_tenant=$(jq -r .tenant "${SP_OUTPUT}")

if [[ "${sp_id}" == "" ]] || [[ "${sp_password}" == "" ]]; then
    echo "Unable to get service principal id or password, exit..."
    exit 1
fi

echo "New service principal id: ${sp_id}"
cat <<EOF > "${SHARED_DIR}/azure_minimal_permission"
{"subscriptionId":"${AZURE_AUTH_SUBSCRIPTOIN_ID}","clientId":"${sp_id}","tenantId":"${sp_tenant}","clientSecret":"${sp_password}"}
EOF

# for destroy
echo "${sp_id}" > "${SHARED_DIR}/azure_sp_id"

rm -f ${SP_OUTPUT}
