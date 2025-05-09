#!/bin/bash

if [ "$ENABLEPEERPODS" != "true" ]; then
    echo "skip as ENABLEPEERPODS is not true"
    exit 0
fi

# Create the parameters configmap file in the shared directory so that others steps
# can reference it.
PP_CONFIGM_PATH="${SHARED_DIR:-$(pwd)}/peerpods-param-cm.yaml"

from_azure_credentials() {
        data="$1"
        oc -n kube-system get secret azure-credentials -o jsonpath="{.data.${data}}" | base64 -d
}

handle_azure() {
    local AZURE_RESOURCE_GROUP
    local AZURE_CLIENT_SECRET
    local AZURE_TENANT_ID
    local AZURE_CLIENT_ID
    local AZURE_VNET_NAME
    local AZURE_SUBNET_ID
    local AZURE_NSG_ID
    local AZURE_REGION

    AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')

    # On jenkins it reads from the AZURE_SECRET_FILE, but that file doesn't exist on prow. Instead, read
    # from ${CLUSTER_PROFILE_DIR} which contain provision files when `cluster_profile` is passed.
    # env.AZURE_CLIENT_ID = sh(script: "cat \$AZURE_SECRET_FILE | jq -r '.clientId'", returnStdout: true).trim()
    # env.AZURE_CLIENT_SECRET = sh(script: "cat \$AZURE_SECRET_FILE | jq -r '.clientSecret'", returnStdout: true).trim()
    # env.AZURE_TENANT_ID = sh(script: "cat \$AZURE_SECRET_FILE | jq -r '.tenantId'", returnStdout: true).trim()
    # env.AZURE_SUBSCRIPTION_ID = sh(script: "cat \$AZURE_SECRET_FILE | jq -r '.subscriptionId'", returnStdout: true).trim()
    if [ -n "${CLUSTER_PROFILE_DIR:-}" ]; then
        echo "TODO: Implement me"
        cat "${CLUSTER_PROFILE_DIR}"/*
    else
        # Useful when testing this script outside of ci-operator
        AZURE_CLIENT_ID="$(from_azure_credentials azure_client_id)"
        AZURE_CLIENT_SECRET="$(from_azure_credentials azure_client_secret)"
        AZURE_SUBSCRIPTION_ID="$(from_azure_credentials azure_subscription_id)"
        AZURE_TENANT_ID="$(from_azure_credentials azure_tenant_id)"
    fi

    set +x
    # TODO: az should be in the image
    az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"

    AZURE_VNET_NAME=$(az network vnet list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[].{Name:name}" --output tsv)
    AZURE_SUBNET_ID=$(az network vnet subnet list --resource-group "${AZURE_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)
    AZURE_NSG_ID=$(az network nsg list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[].{Id:id}" --output tsv)
    AZURE_REGION=$(az group show --resource-group "${AZURE_RESOURCE_GROUP}" --query "{Location:location}" --output tsv)

    echo "****Creating peerpods-param-cm config map with all the cloud params needed for test case execution****"
    cat <<- EOF > "${PP_CONFIGM_PATH}"
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: peerpods-param-cm
      namespace: default
    data:
      CLOUD_PROVIDER: "azure"
      VXLAN_PORT: "9000"
      AZURE_INSTANCE_SIZE: "Standard_B2als_v2"
      AZURE_INSTANCE_SIZES: Standard_B2als_v2,Standard_B2as_v2,Standard_D2as_v5,Standard_B4als_v2,Standard_D4as_v5,Standard_D8as_v5,Standard_NC64as_T4_v3,Standard_NC8as_T4_v3
      AZURE_SUBNET_ID: "${AZURE_SUBNET_ID}"
      AZURE_NSG_ID: "${AZURE_NSG_ID}"
      AZURE_RESOURCE_GROUP: "${AZURE_RESOURCE_GROUP}"
      AZURE_REGION: "${AZURE_REGION}"
      PROXY_TIMEOUT: "30m"
EOF

    echo "****Creating peerpods-param-secret with the keys needed for test case execution****"
    # TODO: create the secret
    #oc create secret generic peerpods-param-secret --from-file=$AZURE_SECRET_FILE -n default
    echo "****Creating peerpods-param-secret COMPLETE****"

    echo "AZURE_RESOURCE_GROUP: $AZURE_RESOURCE_GROUP"
    echo "AZURE_SUBNET_ID: $AZURE_SUBNET_ID"
    echo "AZURE_VNET_NAME: $AZURE_VNET_NAME"
    echo "AZURE_NSG_ID: $AZURE_NSG_ID"

    echo "****Applying peerpods-param-cm on the OCP cluster****"
    az network public-ip create -g "${AZURE_RESOURCE_GROUP}" -n peerpod -l "${AZURE_REGION}" --sku Standard
    az network nat gateway create -g "${AZURE_RESOURCE_GROUP}" -l "${AZURE_REGION}" --public-ip-addresses peerpod -n peerpod
    az network vnet subnet update --nat-gateway peerpod --ids "${AZURE_SUBNET_ID}"
    echo "****Configure Azure network COMPLETE****"
}

echo "Creating peerpods-param-cm for azure"
handle_azure

oc create -f "${PP_CONFIGM_PATH}"