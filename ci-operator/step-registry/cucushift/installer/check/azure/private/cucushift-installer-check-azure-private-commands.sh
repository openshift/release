#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

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

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

critical_check_result=0
#lb check
lb_list=$(az network lb list -g ${RESOURCE_GROUP} -ojson |jq -r '.[].name')
echo "INFO: lb list is ${lb_list}"
internal_lb="${INFRA_ID}-internal"
if [[ "${lb_list}" =~ ${internal_lb} ]]; then
    public_lb=$(echo ${lb_list/"${internal_lb}"} | tr -d '\n')
else
    echo "ERROR: unable to find internal lb ${internal_lb}!"
    exit 1
fi

#lb outbound rule check
echo "Check that outbound rules are created on private cluster..."
outbound_rules=$(az network lb show --name ${public_lb} -g ${RESOURCE_GROUP} -ojson | jq -r ".outboundRules[]")
if [[ -z "${outbound_rules}" ]]; then
    echo "ERROR: Not found outbound rules for public load balancer ${public_lb} on private cluster!"
    critical_check_result=1
else
    echo -e "Found outbound rules for public lb ${public_lb}\n${outbound_rules}"
fi

# lb frontend IP configuration check
echo "Check public ip address of Loadbalance ${public_lb}, should be configured..."
lb_public_ip=""
lb_public_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${public_lb} | jq -r '.frontendIPConfigurations[].publicIPAddress.id')
echo "Public IP configured in frontendIPConfiguration for lb ${public_lb}: ${lb_public_ip}"
if [[ -z ${lb_public_ip} ]] || [[ "${lb_public_ip}" == "null" ]]; then
    echo "ERROR: Unable to find public ip address for load balancer: ${public_lb}"
    critical_check_result=1
fi

#public ip check
echo "Check if any public ip created on private cluster"
public_ip=$(az network public-ip list -g ${RESOURCE_GROUP} -o tsv --query "[].[name,ipAddress]")
echo -e "INFO: public ip: ${public_ip}"
if [[ -z ${public_ip} ]]; then
    echo "ERROR: Not found public ip resource created for outgoing traffic on private cluster, unexpected!"
    critical_check_result=1
fi

if [[ ${critical_check_result} -eq 1 ]]; then
    echo "ERROR: Load Balancer check failed! Found some critical issues."
    exit 1
fi

exit 0
