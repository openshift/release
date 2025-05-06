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

function bootstrap_resource_check()
{
    local sub_command=$1 key_words=$2 additional_options=${3:---query '[].name'} ret=0 az_output

    echo -e "\n**********Check bootstrap related resource ${sub_command}**********"
    echo "Run command: az ${sub_command} list -g ${RESOURCE_GROUP} ${additional_options} -otsv"
    az ${sub_command} list -g ${RESOURCE_GROUP} ${additional_options} -otsv
    az_output=$(az ${sub_command} list -g ${RESOURCE_GROUP} ${additional_options} -otsv | grep ${key_words}) || true
    if [[ -n "${az_output}" ]]; then
        echo -e "ERROR: related resource ${sub_command} is not destroyed.\n${az_output}"
        ret=1
    else
        echo "INFO: related resource ${sub_command} is destroyed."
    fi
    return ${ret}
}

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
KUBECONFIG="" oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret
if (( ${ocp_minor_version} < 17 )); then
    echo "Bootstrap check is only available on 4.17+ capi-based installation, skip the check!"
    exit 0
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

check_result=0
#Check that bootstrap vm/osdisk/nic should be destroyed
bootstrap_host_name="${INFRA_ID}-bootstrap"
bootstrap_resource_check "vm" "${bootstrap_host_name}" || check_result=1
bootstrap_resource_check "disk" "${bootstrap_host_name}" || check_result=1
bootstrap_resource_check "network nic" "${bootstrap_host_name}" || check_result=1
bootstrap_resource_check "network lb inbound-nat-rule" "${INFRA_ID}_ssh_in" "--lb-name ${INFRA_ID} --query [].name" || check_result=1
bootstrap_resource_check "network lb address-pool" "${bootstrap_host_name}" "--lb-name ${INFRA_ID} --query [].loadBalancerBackendAddresses[].name" || check_result=1
bootstrap_resource_check "network nsg" "${INFRA_ID}_ssh_in" "--query [].securityRules[].name" || check_result=1
bootstrap_resource_check "network public-ip" "${bootstrap_host_name}" || check_result=1

exit ${check_result}
