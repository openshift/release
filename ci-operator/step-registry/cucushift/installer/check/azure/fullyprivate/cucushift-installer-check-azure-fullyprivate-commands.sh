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
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

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

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi
ocp_minor_version=$(oc version -ojson | jq -r '.openshiftVersion' | cut -d '.' -f2)

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

critical_check_result=0
no_critical_check_result=0

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

#public lb should not be created on 4.11+
if (( ocp_minor_version >= 11 )); then
    echo "Check that no public load balancer created on fully private cluster..."
    [[ -n "${public_lb}" ]] && echo "ERROR: Found public load balancer ${public_lb} on fully private cluster!" && no_critical_check_result=1
fi

# check lb frontended IP config
for lb in ${lb_list}; do
    echo "Check public ip address of Loadbalance ${lb}, should not be created..."
    lb_public_ip=""
    lb_public_ip=$(az network lb show -g ${RESOURCE_GROUP} -n ${lb} | jq -r '.frontendIPConfigurations[].publicIPAddress.id' | grep -v 'null') || true
    [[ -n ${lb_public_ip} ]] && echo "ERROR: Found public ip address ${lb_public_ip} for load balancer: ${lb}" && critical_check_result=1
done

#public ip check
echo "Check if any public ip created on fully private cluster"
public_ip=$(az network public-ip list -g ${RESOURCE_GROUP} -o tsv --query "[].[name,ipAddress]")
echo -e "INFO: public ip: ${public_ip}"
if [[ -n ${public_ip} ]]; then
    echo "ERROR: found public ip on fully private cluster, unexpected!" && exit 1
    critical_check_result=1
fi

if [[ ${critical_check_result} -eq 1 ]]; then
    echo "ERROR: Load Balancer check failed! Found some critical issues."
    exit 1
fi

if [[ ${no_critical_check_result} -eq 1 ]]; then
    echo "ERROR: Load Balancer check failed! Found some issues."
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
fi 
exit 0
