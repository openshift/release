#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "ERROR: env 'BASE_DOMAIN' is not set, could not be empty, please check!"
    exit 1
fi

function get_lb_ip() {

    local lb_name=$1 port=$2 out=$3

    frontendipconfig_id=$(az network lb show -n ${lb_name} -g ${RESOURCE_GROUP} -ojson | jq -r ".loadBalancingRules[] | select(.frontendPort == ${port}) | .frontendIPConfiguration.id")
    frontendipconfig_name=${frontendipconfig_id##*/}

    lb_ip=$(az network lb frontend-ip show -n ${frontendipconfig_name} --lb-name ${lb_name} -g ${RESOURCE_GROUP} --query "privateIPAddress" -otsv)
    echo "LB rule's(port: ${port}) frontend private IP in internal LB: ${lb_ip}"
    echo "${lb_ip}" > ${out}
}

# az should already be there
command -v az
az --version

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"
AZURE_AUTH_SUBSCRIPTION_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .subscriptionId)"

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
az account set --subscription ${AZURE_AUTH_SUBSCRIPTION_ID}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

# api server
get_lb_ip "${INFRA_ID}-internal" "6443" "${ARTIFACT_DIR}/apiserver_lb_ip"
api_lb_ip="$(< "${ARTIFACT_DIR}/apiserver_lb_ip")"
if [[ -n "${api_lb_ip}" ]]; then
    echo "api.${CLUSTER_NAME}.${BASE_DOMAIN} ${api_lb_ip}" >> "${SHARED_DIR}/custom_dns"
else
    echo "Unable to get apiserver rule's frontend IP from internal load balancer!"
    exit 1
fi

# ingress
get_lb_ip "${INFRA_ID}-internal" "443" "${ARTIFACT_DIR}/ingress_lb_ip"
ingress_lb_ip="$(< "${ARTIFACT_DIR}/ingress_lb_ip")"
if [[ -n "${ingress_lb_ip}" ]]; then
    echo "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN} ${ingress_lb_ip}" >> "${SHARED_DIR}/custom_dns"
else
    echo "Unable to get ingress rule's frontend IP from internal load balancer!"
    exit 1
fi

echo "customer-dns:"
cat "${SHARED_DIR}"/custom_dns
