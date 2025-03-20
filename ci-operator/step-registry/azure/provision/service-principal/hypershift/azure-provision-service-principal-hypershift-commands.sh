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
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

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
    role="b24988ac-6180-42a0-ab88-20f7382dd24c"

    if [[ $component == ingress ]]; then
          role="0336e1d3-7a87-462b-b6db-342b63f7802c"
          scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == cloud-provider ]]; then
        role="a1f96423-95ce-4224-ab27-4e3dc72facd4"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
    elif [[ $component == cpo ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == capz ]]; then
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == azure-file ]]; then
        role="0d7aedc0-15fd-4a67-a412-efad370c947e"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_NSG"
        scopes+=" /subscriptions/$AZURE_AUTH_SUBSCRIPTION_ID/resourceGroups/$RG_VNET"
    elif [[ $component == azure-disk ]]; then
        role="5b7237c5-45e1-49d6-bc18-a1f62f400748"
    elif [[ $component == cncc ]]; then
        role="be7a6435-15ae-4171-8f30-4a343eff9e8f"
    elif [[ $component == ciro ]]; then
        role="8b32b316-c2f5-4ddf-b05b-83dacd2d08b5"
    fi

    client_id="$(eval "az ad sp create-for-rbac --name $name --role \"$role\" --scopes $scopes --create-cert --cert $name --keyvault $KV_NAME --output json --only-show-errors" | jq -r '.appId')"
    echo "$client_id" >> "${SHARED_DIR}/azure_sp_id"

    component_to_client_id+=(["$component"]="$client_id")
    component_to_cert_name+=(["$component"]="$name")
done

## create secret json files
for component in "${!component_to_cert_name[@]}"; do
    CERT_NAME="${component_to_cert_name[$component]}"
    echo "Processing certificate: $CERT_NAME"

    CERT_DETAILS=$(az keyvault secret show --vault-name $KV_NAME --name $CERT_NAME --query "{value: value, notBefore: attributes.notBefore, expires: attributes.expires}" -o json)
    CLIENT_SECRET=$(echo $CERT_DETAILS | jq -r '.value')
    NOT_BEFORE=$(echo $CERT_DETAILS | jq -r '.notBefore')
    NOT_AFTER=$(echo $CERT_DETAILS | jq -r '.expires')
    SP_DETAILS=$(az ad sp list --display-name $CERT_NAME --query "[0].{client_id: appId, tenant_id: appOwnerOrganizationId}" -o json)
    CLIENT_ID=$(echo $SP_DETAILS | jq -r '.client_id')
    TENANT_ID=$(echo $SP_DETAILS | jq -r '.tenant_id')

    if [[ -z "$CLIENT_ID" || -z "$TENANT_ID" ]]; then
        echo "Error: Could not retrieve client ID or tenant ID for certificate: $CERT_NAME"
        continue
    fi

    JSON_FILE="${SHARED_DIR}/${CERT_NAME}.json"
    echo "{
        \"authentication_endpoint\": \"https://login.microsoftonline.com/\",
        \"client_id\": \"$CLIENT_ID\",
        \"client_secret\": \"$CLIENT_SECRET\",
        \"tenant_id\": \"$TENANT_ID\",
        \"not_before\": \"$NOT_BEFORE\",
        \"not_after\": \"$NOT_AFTER\"
    }" > "${JSON_FILE}"

    echo "Created JSON file: ${JSON_FILE}"
    az keyvault secret set --name "${CERT_NAME}-json" --vault-name "${KV_NAME}" --file "${JSON_FILE}"
done

# TODO: Remove this once the we used the automated role assignment by "--assign-service-principal-role"
az role assignment create \
  --assignee "${component_to_client_id[ingress]}"\
  --role "Contributor" \
  --scope  /subscriptions/"$AZURE_AUTH_SUBSCRIPTION_ID"/resourceGroups/"$BASE_DOMAIN_RESOURCE_GROUP"

az role assignment list --assignee "${component_to_client_id[ingress]}" --scope /subscriptions/"$AZURE_AUTH_SUBSCRIPTION_ID"/resourceGroups/"$BASE_DOMAIN_RESOURCE_GROUP" --query '[].id' -otsv >> "${SHARED_DIR}/azure_role_assignment_ids"

cat <<EOF >"${SHARED_DIR}"/hypershift_azure_mi_file.json
{
    "managedIdentitiesKeyVault": {
        "name": "$KV_NAME",
        "tenantID": "$AZURE_AUTH_TENANT_ID"
    },
    "cloudProvider": {
        "clientID": "${component_to_client_id[cloud-provider]}",
        "certificateName": "${component_to_cert_name[cloud-provider]}",
        "credentialsSecretName": "${component_to_cert_name[cloud-provider]}-json",
        "objectEncoding": "utf-8"
    },
    "nodePoolManagement": {
        "clientID": "${component_to_client_id[capz]}",
        "certificateName": "${component_to_cert_name[capz]}",
        "credentialsSecretName": "${component_to_cert_name[capz]}-json",
        "objectEncoding": "utf-8"
    },
    "controlPlaneOperator": {
        "clientID": "${component_to_client_id[cpo]}",
        "certificateName": "${component_to_cert_name[cpo]}",
        "credentialsSecretName": "${component_to_cert_name[cpo]}-json",
        "objectEncoding": "utf-8"
    },
    "imageRegistry": {
        "clientID": "${component_to_client_id[ciro]}",
        "certificateName": "${component_to_cert_name[ciro]}",
        "credentialsSecretName": "${component_to_cert_name[ciro]}-json",
        "objectEncoding": "utf-8"
    },
    "ingress": {
        "clientID": "${component_to_client_id[ingress]}",
        "certificateName": "${component_to_cert_name[ingress]}",
        "credentialsSecretName": "${component_to_cert_name[ingress]}-json",
        "objectEncoding": "utf-8"
    },
    "network": {
        "clientID": "${component_to_client_id[cncc]}",
        "certificateName": "${component_to_cert_name[cncc]}",
        "credentialsSecretName": "${component_to_cert_name[cncc]}-json",
        "objectEncoding": "utf-8"
    },
    "disk": {
        "clientID": "${component_to_client_id[azure-disk]}",
        "certificateName": "${component_to_cert_name[azure-disk]}",
        "credentialsSecretName": "${component_to_cert_name[azure-disk]}-json",
        "objectEncoding": "utf-8"
    },
    "file": {
        "clientID": "${component_to_client_id[azure-file]}",
        "certificateName": "${component_to_cert_name[azure-file]}",
        "credentialsSecretName": "${component_to_cert_name[azure-file]}-json",
        "objectEncoding": "utf-8"
    }
}
EOF

# Create and Save Managed Identities for the Data Plane Component
AZURE_DISK_MI_NAME="${SP_NAME_PREFIX}-disk-dp-mi"
AZURE_FILE_MI_NAME="${SP_NAME_PREFIX}-file-dp-mi"
IMAGE_REGISTRY_MI_NAME="${SP_NAME_PREFIX}-image-registry-dp-mi"
AZURE_DISK_CLIENT_ID=$(az identity create --name "$AZURE_DISK_MI_NAME" --resource-group "$RG_HC" --query clientId -o tsv)
AZURE_FILE_CLIENT_ID=$(az identity create --name "$AZURE_FILE_MI_NAME" --resource-group "$RG_HC" --query clientId -o tsv)
IMAGE_REGISTRY_CLIENT_ID=$(az identity create --name "$IMAGE_REGISTRY_MI_NAME" --resource-group "$RG_HC" --query clientId -o tsv)

cat <<EOF >"${SHARED_DIR}"/hypershift_azure_dp_mi_file.json
{
  "imageRegistryMSIClientID": ${IMAGE_REGISTRY_CLIENT_ID},
  "diskMSIClientID": ${AZURE_DISK_CLIENT_ID},
  "fileMSIClientID": ${AZURE_FILE_CLIENT_ID}
}
EOF

## create federated identities for workload identities
OIDC_ISSUER_URL="$(cat /etc/hypershift-aro-oidc-issuer/hypershift-aro-oidc-issuer)"

az identity federated-credential create --name "${AZURE_DISK_MI_NAME}"-fed-id \
--identity-name "${AZURE_DISK_MI_NAME}" \
--resource-group "$RG_HC" \
--issuer "${OIDC_ISSUER_URL}" \
--subject system:serviceaccount:openshift-cluster-csi-drivers:azure-disk-csi-driver-node-sa \
--audience openshift

az identity federated-credential create --name "${AZURE_FILE_MI_NAME}"-fed-id \
--identity-name "${AZURE_FILE_MI_NAME}" \
--resource-group "$RG_HC" \
--issuer "${OIDC_ISSUER_URL}" \
--subject system:serviceaccount:openshift-cluster-csi-drivers:azure-file-csi-driver-node-sa \
--audience openshift

az identity federated-credential create --name "${IMAGE_REGISTRY_MI_NAME}"-fed-id \
--identity-name "${IMAGE_REGISTRY_MI_NAME}" \
--resource-group "$RG_HC" \
--issuer "${OIDC_ISSUER_URL}" \
--subject system:serviceaccount:openshift-image-registry:cluster-image-registry-operator \
--audience openshift

az identity federated-credential create --name "${IMAGE_REGISTRY_MI_NAME}"-fed-id \
--identity-name "${IMAGE_REGISTRY_MI_NAME}" \
--resource-group "$RG_HC" \
--issuer "${OIDC_ISSUER_URL}" \
--subject system:serviceaccount:openshift-image-registry:registry \
--audience openshift

