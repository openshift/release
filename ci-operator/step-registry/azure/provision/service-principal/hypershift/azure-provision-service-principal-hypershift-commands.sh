#!/usr/bin/env bash

set -euo pipefail

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

az --version
az cloud set --name AzureCloud
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

set -x

SP_NAME_PREFIX="${NAMESPACE}-${UNIQUE_HASH}"
KV_NAME=$(<"${SHARED_DIR}/azure_keyvault_name")
RG_NSG=$(<"${SHARED_DIR}/resourcegroup_nsg")
RG_VNET=$(<"${SHARED_DIR}/resourcegroup_vnet")
RG_HC=$(<"${SHARED_DIR}/resourcegroup")
COMPONENTS="azure-disk azure-file ciro cloud-provider cncc cpo ingress capz"

declare -A component_to_client_id
declare -A component_to_cert_name

for component in $COMPONENTS; do
    name="${SP_NAME_PREFIX}-${component}"
    scopes="/subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_HC"
    if [[ $component == ingress ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == cloud-provider ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    elif [[ $component == cpo ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == capz ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    fi

    client_id="$(eval "az ad sp create-for-rbac --name $name --role Contributor --scopes $scopes --create-cert --cert $name --keyvault $KV_NAME --output json --only-show-errors" | jq -r '.appId')"
    echo "$client_id" >> "${SHARED_DIR}/azure_sp_id"

    component_to_client_id+=(["$component"]="$client_id")
    component_to_cert_name+=(["$component"]="$name")
done

# TODO: Remove this once the we used the automated role assignment by "--assign-service-principal-role"
az role assignment create \
  --assignee "${component_to_client_id[ingress]}"\
  --role "Contributor" \
  --scope  /subscriptions/"$AZURE_AUTH_SUBSCRIPTION_ID"/resourceGroups/"$BASE_DOMAIN_RESOURCE_GROUP"

az role assignment list --assignee "${component_to_client_id[ingress]}" --query '[].id' -otsv >> "${SHARED_DIR}/azure_role_assignment_ids"

cat <<EOF >"${SHARED_DIR}"/hypershift_azure_mi_file.json
{
    "managedIdentitiesKeyVault": {
        "name": "$KV_NAME",
        "tenantID": "$AZURE_AUTH_TENANT_ID"
    },
    "cloudProvider": {
        "clientID": "${component_to_client_id[cloud-provider]}",
        "certificateName": "${component_to_cert_name[cloud-provider]}"
    },
    "nodePoolManagement": {
        "clientID": "${component_to_client_id[capz]}",
        "certificateName": "${component_to_cert_name[capz]}"
    },
    "controlPlaneOperator": {
        "clientID": "${component_to_client_id[cpo]}",
        "certificateName": "${component_to_cert_name[cpo]}"
    },
    "imageRegistry": {
        "clientID": "${component_to_client_id[ciro]}",
        "certificateName": "${component_to_cert_name[ciro]}"
    },
    "ingress": {
        "clientID": "${component_to_client_id[ingress]}",
        "certificateName": "${component_to_cert_name[ingress]}"
    },
    "network": {
        "clientID": "${component_to_client_id[cncc]}",
        "certificateName": "${component_to_cert_name[cncc]}"
    },
    "disk": {
        "clientID": "${component_to_client_id[azure-disk]}",
        "certificateName": "${component_to_cert_name[azure-disk]}"
    },
    "file": {
        "clientID": "${component_to_client_id[azure-file]}",
        "certificateName": "${component_to_cert_name[azure-file]}"
    }
}
EOF
