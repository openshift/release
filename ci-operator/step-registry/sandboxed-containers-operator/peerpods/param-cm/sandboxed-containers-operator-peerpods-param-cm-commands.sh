#!/bin/bash

if [ "$ENABLEPEERPODS" != "true" ]; then
    echo "skip as ENABLEPEERPODS is not true"
    exit 0
fi

# Switch to a directory with rw permission
cd /tmp || exit 1

# Create the parameters configmap file in the shared directory so that others steps
# can reference it.
PP_CONFIGM_PATH="${SHARED_DIR:-$(pwd)}/peerpods-param-cm.yaml"

handle_azure() {
    local AZURE_RESOURCE_GROUP
    local AZURE_AUTH_LOCATION
    local AZURE_CLIENT_SECRET
    local AZURE_TENANT_ID
    local AZURE_CLIENT_ID
    local AZURE_VNET_ID
    local AZURE_VNET_NAME
    local AZURE_SUBNET_ID
    local AZURE_SUBNET_NAME
    local AZURE_NSG_ID
    local AZURE_REGION
    local PP_REGION
    local PP_RESOURCE_GROUP
    local PP_VNET_ID
    local PP_VNET_NAME
    local PP_SUBNET_NAME
    local PP_SUBNET_ID
    local PP_RESOURCE_GROUP
    local PP_NSG_ID
    local PP_NSG_NAME

    # Note: Keep the following commands in sync with https://raw.githubusercontent.com/kata-containers/kata-containers/refs/heads/main/ci/openshift-ci/peer-pods-azure.sh
    # as much as possible.

    ###############################
    # Disable security to allow e2e
    ###############################

    # Disable security
    oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
    oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts
    oc label --overwrite ns default pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=baseline pod-security.kubernetes.io/audit=baseline

    oc -n kube-system get secret azure-credentials -o json > azure_credentials.json
    if [ -n "${CLUSTER_PROFILE_DIR:-}" ]; then
        AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
        AZURE_CLIENT_ID="$(jq -r .clientId "${AZURE_AUTH_LOCATION}")"
        AZURE_CLIENT_SECRET="$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")"
        AZURE_TENANT_ID="$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")"
    else
        # Useful when testing this script outside of ci-operator
        AZURE_CLIENT_ID="$(jq -r .data.azure_client_id azure_credentials.json|base64 -d)"
        AZURE_CLIENT_SECRET="$(jq -r .data.azure_client_secret azure_credentials.json|base64 -d)"
        AZURE_TENANT_ID="$(jq -r .data.azure_tenant_id azure_credentials.json|base64 -d)"
    fi
    AZURE_SUBSCRIPTION_ID="$(jq -r .data.azure_subscription_id azure_credentials.json|base64 -d)"
    rm -f azure_credentials.json

    AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
    az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
    # Recommended on az sites to refresh the subscription
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}"
    # This command still sometimes fails directly after login
    for I in {1..30}; do
	    AZURE_VNET_NAME=$(az network vnet list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[].{Name:name}" --output tsv ||:)
	    if [[ -z "${AZURE_VNET_NAME}" ]]; then
		    sleep "${I}"
	    else	# VNET set, we are done
		    break
	    fi
    done
    if [[ -z "${AZURE_VNET_NAME}" ]]; then
	    echo "Failed to get AZURE_VNET_NAME in 30 iterations"
	    exit 1
    fi

    AZURE_SUBNET_NAME=$(az network vnet subnet list --resource-group "${AZURE_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --query "[].{Id:name} | [? contains(Id, 'worker')]" --output tsv)
    AZURE_SUBNET_ID=$(az network vnet subnet list --resource-group "${AZURE_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)
    AZURE_NSG_ID=$(az network nsg list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[].{Id:id}" --output tsv)
    AZURE_REGION=$(az group show --resource-group "${AZURE_RESOURCE_GROUP}" --query "{Location:location}" --output tsv)

    PP_REGION=eastus
    if [[ "${AZURE_REGION}" == "${PP_REGION}" ]]; then
        echo "Using the current region ${AZURE_REGION}"
        PP_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
        PP_VNET_NAME="${AZURE_VNET_NAME}"
        PP_SUBNET_NAME="${AZURE_SUBNET_NAME}"
        PP_SUBNET_ID="${AZURE_SUBNET_ID}"
        PP_NSG_ID="${AZURE_NSG_ID}"
    else
        echo "Creating peering between ${AZURE_REGION} and ${PP_REGION}"
        PP_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}-eastus"
        PP_VNET_NAME="${AZURE_VNET_NAME}-eastus"
        PP_SUBNET_NAME="${AZURE_SUBNET_NAME}-eastus"
        PP_NSG_NAME="${AZURE_VNET_NAME}-nsg-eastus"
        az group create --name "${PP_RESOURCE_GROUP}" --location "${PP_REGION}"
        az network vnet create --resource-group "${PP_RESOURCE_GROUP}" --name "${PP_VNET_NAME}" --location "${PP_REGION}" --address-prefixes 10.2.0.0/16 --subnet-name "${PP_SUBNET_NAME}" --subnet-prefixes 10.2.1.0/24
        az network nsg create --resource-group "${PP_RESOURCE_GROUP}" --name "${PP_NSG_NAME}" --location "${PP_REGION}"
        az network vnet subnet update --resource-group "${PP_RESOURCE_GROUP}" --vnet-name "${PP_VNET_NAME}" --name "${PP_SUBNET_NAME}" --network-security-group "${PP_NSG_NAME}"
        AZURE_VNET_ID=$(az network vnet show --resource-group "${AZURE_RESOURCE_GROUP}" --name "${AZURE_VNET_NAME}" --query id --output tsv)
        PP_VNET_ID=$(az network vnet show --resource-group "${PP_RESOURCE_GROUP}" --name "${PP_VNET_NAME}" --query id --output tsv)
        az network vnet peering create --name westus-to-eastus --resource-group "${AZURE_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --remote-vnet "${PP_VNET_ID}" --allow-vnet-access
        az network vnet peering create --name eastus-to-westus --resource-group "${PP_RESOURCE_GROUP}" --vnet-name "${PP_VNET_NAME}" --remote-vnet "${AZURE_VNET_ID}" --allow-vnet-access
        PP_SUBNET_ID=$(az network vnet subnet list --resource-group "${PP_RESOURCE_GROUP}" --vnet-name "${PP_VNET_NAME}" --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)
        PP_NSG_ID=$(az network nsg list --resource-group "${PP_RESOURCE_GROUP}" --query "[].{Id:id}" --output tsv)
fi

    # Peer-pod requires gateway
    az network public-ip create \
        --resource-group "${PP_RESOURCE_GROUP}" \
        --name MyPublicIP \
        --sku Standard \
        --allocation-method Static
    az network nat gateway create \
        --resource-group "${PP_RESOURCE_GROUP}" \
        --name MyNatGateway \
        --public-ip-addresses MyPublicIP \
        --idle-timeout 10
    az network vnet subnet update \
        --resource-group "${PP_RESOURCE_GROUP}" \
        --vnet-name "${PP_VNET_NAME}" \
        --name "${PP_SUBNET_NAME}" \
        --nat-gateway MyNatGateway

    # Start the downstream-only commands

    # Creating peerpods-param-cm config map with all the cloud params needed for test case execution
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
      AZURE_SUBNET_ID: "${PP_SUBNET_ID}"
      AZURE_NSG_ID: "${PP_NSG_ID}"
      AZURE_RESOURCE_GROUP: "${PP_RESOURCE_GROUP}"
      AZURE_REGION: "${PP_REGION}"
      PROXY_TIMEOUT: "30m"
EOF

    if [[ -z "${AZURE_AUTH_LOCATION}" ]]; then
        AZURE_AUTH_LOCATION="${PWD}/osServicePrincipal.json"
        echo "{ \"clientId\": \"$AZURE_CLIENT_ID\", \"clientSecret\": \"$AZURE_CLIENT_SECRET\", \"tenantId\": \"$AZURE_TENANT_ID\" }" | \
            jq > "${AZURE_AUTH_LOCATION}"
    fi
    # Creating peerpods-param-secret with the keys needed for test case execution
    oc create secret generic peerpods-param-secret --from-file="${AZURE_AUTH_LOCATION}" -n default
}

echo "Creating peerpods-param-cm for azure"
handle_azure

oc create -f "${PP_CONFIGM_PATH}"