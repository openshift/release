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

function create_role_definition_json() {

    local role_name=$1 permissions=$2 role_definition_file=$3

    role_description="the custom role ${role_name} with minimal permissions for cluster ${CLUSTER_NAME}"
    assignable_scopes="""
\"/subscriptions/${AZURE_AUTH_SUBSCRIPTION_ID}\"
"""

    # create role definition json file
    jq --null-input \
       --arg role_name "${role_name}" \
       --arg description "${role_description}" \
       --argjson assignable_scopes "[ ${assignable_scopes} ]" \
       --argjson permission_list "[ ${permissions} ]" '
{
  "Name": $role_name,
  "IsCustom": true,
  "Description": $description,
  "assignableScopes": $assignable_scopes,
  "Actions": $permission_list,
  "notActions": [],
  "dataActions": [],
  "notDataActions": []
}' > "${role_definition_file}"
}

function create_custom_role() {
    local role_definition="$1"

    # create custom role
    cmd="az role definition create --role-definition ${role_definition}"
    run_command "${cmd}" || return 1

    echo "Sleep 1 min to wait for custom role created"
    sleep 60
}

if [[ "${AZURE_INSTALL_USE_MINIMAL_PERMISSIONS}" == "no" ]] && [[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "false" ]]; then
    echo "Both AZURE_INSTALL_USE_MINIMAL_PERMISSIONS and ENABLE_MIN_PERMISSION_FOR_STS are disabled, skip this step to create custom role with minimal permission!"
    exit 0
fi

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
if [[ -f "${CLUSTER_PROFILE_DIR}/installer-sp-minter.json" ]]; then
    AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/installer-sp-minter.json"
fi
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]] || [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    echo "Installation with minimal permissions is only supported on Azure Public Cloud so far, exit..."
    exit 1
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
custom_role_name_json="{}"
# create custom role with minimal permission for cluster to create the infrastructure.
if [[ "${AZURE_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then
    ROLE_DEFINITION="${ARTIFACT_DIR}/azure-custom-role-definition-minimal-permissions.json"
    CUSTOM_ROLE_NAME="${CLUSTER_NAME}-custom-role"
    CONFIG="${SHARED_DIR}/install-config.yaml"

    install_config_vnet=$(yq-go r ${CONFIG} 'platform.azure.virtualNetwork')
    install_config_osimage_default=$(yq-go r ${CONFIG} 'platform.azure.defaultMachinePlatform.osImage')
    install_config_osimage_master=$(yq-go r ${CONFIG} 'controlPlane.platform.azure.osImage')
    install_config_osimage_worker=$(yq-go r ${CONFIG} 'compute[0].platform.azure.osImage')
    install_config_des_default=$(yq-go r ${CONFIG} 'platform.azure.defaultMachinePlatform.osDisk.diskEncryptionSet')
    install_config_des_master=$(yq-go r ${CONFIG} 'controlPlane.platform.azure.osDisk.diskEncryptionSet')
    install_config_des_worker=$(yq-go r ${CONFIG} 'compute[0].platform.azure.osDisk.diskEncryptionSet')
    install_config_identity_type_default=$(yq-go r ${CONFIG} 'platform.azure.defaultMachinePlatform.identity.type')
    install_config_user_identity_default=$(yq-go r ${CONFIG} 'platform.azure.defaultMachinePlatform.identity.userAssignedIdentities')
    install_config_identity_type_master=$(yq-go r ${CONFIG} 'controlPlane.platform.azure.identity.type')
    install_config_user_identity_master=$(yq-go r ${CONFIG} 'controlPlane.platform.azure.identity.userAssignedIdentities')
    install_config_identity_type_compute=$(yq-go r ${CONFIG} 'compute[0].platform.azure.identity.type')
    install_config_user_identity_compute=$(yq-go r ${CONFIG} 'compute[0].platform.azure.identity.userAssignedIdentities')
    install_config_outbound_type=$(yq-go r ${CONFIG} 'platform.azure.outboundType')
    install_config_publish_strategy=$(yq-go r ${CONFIG} 'publish')
    install_config_customer_managed_key=$(yq-go r ${CONFIG} 'platform.azure.customerManagedKey')

    required_permissions="""
\"Microsoft.Authorization/policies/audit/action\",
\"Microsoft.Authorization/policies/auditIfNotExists/action\",
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
\"Microsoft.Compute/disks/delete\",
\"Microsoft.Compute/galleries/delete\",
\"Microsoft.Compute/galleries/images/delete\",
\"Microsoft.Compute/galleries/images/versions/delete\",
\"Microsoft.Compute/virtualMachines/delete\",
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
\"Microsoft.Resources/subscriptions/resourcegroups/delete\",
\"Microsoft.Storage/storageAccounts/delete\",
\"Microsoft.Storage/storageAccounts/listKeys/action\"
"""

    # optional permissions for external dns operator
    required_permissions="""
\"Microsoft.Network/privateDnsZones/CNAME/read\",
\"Microsoft.Network/privateDnsZones/CNAME/write\",
\"Microsoft.Network/privateDnsZones/CNAME/delete\",
\"Microsoft.Network/privateDnsZones/TXT/read\",
\"Microsoft.Network/privateDnsZones/TXT/write\",
\"Microsoft.Network/privateDnsZones/TXT/delete\",
${required_permissions}
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

    # Starting from 4.19, user-assigned identity created by installer is removed, related permissions are not required any more.
    # The default behavior is changed to create an identity via installer#9735, will change back once future upstream changes land
    # optional permissions are not required with below configurations
    # * identity type is set to None
    # * identity type is set to UserAssigned without precreated user-assigned identity
    default_identity_type="UserAssigned"
    master_identity_type=${default_identity_type}
    master_user_identity=""
    worker_identity_type=${default_identity_type}
    worker_user_identity=""
    if [[ -n "${install_config_identity_type_default}" ]]; then
        master_identity_type="${install_config_identity_type_default}"
        worker_identity_type="${install_config_identity_type_default}"
        if [[ -n "${install_config_user_identity_default}" ]]; then
            master_user_identity="${install_config_user_identity_default}"
            worker_user_identity="${install_config_user_identity_default}"
        fi
    fi
    if [[ -n "${install_config_identity_type_master}" ]]; then
        master_identity_type="${install_config_identity_type_master}"
        if [[ -n "${install_config_user_identity_master}" ]]; then
            master_user_identity="${install_config_user_identity_master}"
        fi
    fi
    if [[ -n "${install_config_identity_type_compute}" ]]; then
        worker_identity_type="${install_config_identity_type_compute}"
        if [[ -n "${install_config_user_identity_compute}" ]]; then
            worker_user_identity="${install_config_user_identity_compute}"
        fi
    fi

    if [[ "${master_identity_type}" == "UserAssigned" && -z "${master_user_identity}" ]] || [[ "${worker_identity_type}" == "UserAssigned" && -z "${worker_user_identity}" ]]; then
        required_permissions="""
\"Microsoft.ManagedIdentity/userAssignedIdentities/assign/action\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/read\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/write\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/delete\",
\"Microsoft.Authorization/roleAssignments/read\",
\"Microsoft.Authorization/roleAssignments/write\",
\"Microsoft.Authorization/roleAssignments/delete\",
${required_permissions}
"""
    # Optional permissions when configuring identity type to UserAssigned with precreated user-assigend identity
    elif [[ -n "${master_user_identity}" ]] || [[ -n "${worker_user_identity}" ]]; then
    required_permissions="""
\"Microsoft.ManagedIdentity/userAssignedIdentities/assign/action\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/read\",
${required_permissions}
"""
    fi

    # optional permissions when enabling customer managed key
    if [[ -n "${install_config_customer_managed_key}" ]]; then
        required_permissions="""
\"Microsoft.ManagedIdentity/userAssignedIdentities/assign/action\",
\"Microsoft.KeyVault/vaults/*/read\",
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

    # optional permissions for fully private/internal image registry clusters used for azure file csi driver
    registry_conf="${SHARED_DIR}/manifest_image_registry-config.yml"
    registry_type=""
    if [[ -f "${registry_conf}" ]]; then
        registry_type=$(yq-go r "${registry_conf}" 'spec.storage.azure.networkAccess.type')
    fi
    if [[ "${registry_type}" == "Internal" ]] || \
       { [[ "${install_config_publish_strategy}" == "Internal" ]] && \
       [[ "${install_config_outbound_type}" == "UserDefinedRouting" ]]; }; then
        required_permissions="""
\"Microsoft.Network/privateEndpoints/write\",
\"Microsoft.Network/privateEndpoints/read\",
\"Microsoft.Network/privateEndpoints/privateDnsZoneGroups/write\",
\"Microsoft.Network/privateEndpoints/privateDnsZoneGroups/read\",
\"Microsoft.Network/privateDnsZones/join/action\",
\"Microsoft.Storage/storageAccounts/PrivateEndpointConnectionsApproval/action\",
${required_permissions}
"""
    fi

    # optional permissions when installing cluster in existing vnet
    if [[ -n ${install_config_vnet} ]] && (( ocp_minor_version >= 17 && ocp_major_version == 4 )); then
        required_permissions="""
\"Microsoft.Network/virtualNetworks/checkIpAddressAvailability/read\",
${required_permissions}
"""
    fi

    # optional permissions when installing fullyprivate cluster and using natgateway as outbound
    if [[ "${install_config_outbound_type}" == "UserDefinedRouting" ]] && [[ "${OUTBOUND_UDR_TYPE}" == "NAT" ]]; then
        required_permissions="""
\"Microsoft.Network/natGateways/join/action\",
\"Microsoft.Network/natGateways/read\",
\"Microsoft.Network/natGateways/write\",
${required_permissions}
"""

    fi

    if [[ -n "${install_config_osimage_default}" ]] || [[ -n "${install_config_osimage_master}" ]] || [[ -n "${install_config_osimage_worker}" ]]; then
        required_permissions="""
\"Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/read\",
\"Microsoft.MarketplaceOrdering/offertypes/publishers/offers/plans/agreements/write\",
\"Microsoft.Compute/images/read\",
\"Microsoft.Compute/images/write\",
\"Microsoft.Compute/images/delete\",
${required_permissions}
"""    
    fi

    if [[ -n "${install_config_des_default}" ]] || [[ -n "${install_config_des_master}" ]] || [[ -n "${install_config_des_worker}" ]]; then
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

    # optional permissions when installing cluster with outbond type is NATGatewaySingleZone NATGatewayMultiZone NatGateway
    if [[ "${install_config_outbound_type}" == "NATGatewaySingleZone" ]] || [[ "${install_config_outbound_type}" == "NATGatewayMultiZone" ]] || [[ "${install_config_outbound_type}" == "NatGateway" ]]; then
         required_permissions="""
\"Microsoft.Network/natGateways/join/action\",
\"Microsoft.Network/natGateways/read\",
\"Microsoft.Network/natGateways/write\",
${required_permissions}
"""

    fi

    create_role_definition_json "${CUSTOM_ROLE_NAME}" "${required_permissions}" "${ROLE_DEFINITION}"
    echo "Creating custom role..."
    create_custom_role "${ROLE_DEFINITION}"
    # for destroy
    custom_role_name_json=$(echo "${custom_role_name_json}" | jq -c -S ". +={\"cluster\":\"${CUSTOM_ROLE_NAME}\"}")
    echo "${custom_role_name_json}" > "${SHARED_DIR}/azure_custom_role_name"
fi

# create custom role with minimal permission for ccoctl to create required Azure resources when using workload identity
if [[ "${ENABLE_MIN_PERMISSION_FOR_STS}" == "true" ]]; then
    sts_required_permissions="""
\"Microsoft.Resources/subscriptions/resourceGroups/read\",
\"Microsoft.Resources/subscriptions/resourceGroups/write\",
\"Microsoft.Resources/subscriptions/resourceGroups/delete\",
\"Microsoft.Authorization/roleAssignments/read\",
\"Microsoft.Authorization/roleAssignments/delete\",
\"Microsoft.Authorization/roleAssignments/write\",
\"Microsoft.Authorization/roleDefinitions/read\",
\"Microsoft.Authorization/roleDefinitions/write\",
\"Microsoft.Authorization/roleDefinitions/delete\",
\"Microsoft.Storage/storageAccounts/listkeys/action\",
\"Microsoft.Storage/storageAccounts/delete\",
\"Microsoft.Storage/storageAccounts/read\",
\"Microsoft.Storage/storageAccounts/write\",
\"Microsoft.Storage/storageAccounts/blobServices/containers/write\",
\"Microsoft.Storage/storageAccounts/blobServices/containers/delete\",
\"Microsoft.Storage/storageAccounts/blobServices/containers/read\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/delete\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/read\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/write\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/read\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/write\",
\"Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials/delete\",
\"Microsoft.Storage/register/action\",
\"Microsoft.ManagedIdentity/register/action\"
"""
    sts_role_name="${CLUSTER_NAME}-custom-role-sts"
    sts_role_definition="${ARTIFACT_DIR}/azure-custom-role-definition-sts-minimal-permissions.json"

    create_role_definition_json "${sts_role_name}" "${sts_required_permissions}" "${sts_role_definition}"
    create_custom_role "${sts_role_definition}"
    # for destroy
    custom_role_name_json=$(echo "${custom_role_name_json}" | jq -c -S ". +={\"sts\":\"${sts_role_name}\"}")
    echo "${custom_role_name_json}" > "${SHARED_DIR}/azure_custom_role_name"
fi
