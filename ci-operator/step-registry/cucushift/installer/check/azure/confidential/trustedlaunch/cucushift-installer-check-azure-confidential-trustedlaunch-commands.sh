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

function property_check() {
    local node_name=$1
    local property=$2
    local expected_value=$3
    local profile=$4

    actual_value=$(cat ${profile} | jq -r ".${property}")
    [[ "${expected_value}" == "Disabled" ]] && [[ "${actual_value}" == "false" ]] && return 0
    [[ "${expected_value}" == "Enabled" ]] && [[ "${actual_value}" == "true" ]] && return 0
    [[ "${expected_value}" == "${actual_value}" ]] && [[ "${actual_value}" != "null" ]] && return 0

    echo "ERROR: property ${property} on node ${node_name} compared failed, expected value: ${expected_value}, acutal value: ${actual_value}"
    return 1
}

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

critical_check_result=0

# machine check
# expected values are from step `ipi-conf-azure-confidential-trustedlaunch`
encryptionathost="true"
security_type="TrustedLaunch"
secure_boot="Enabled"
vtpm="Enabled"

nodes_list=$(oc get nodes --no-headers | awk '{print $1}')
for node in ${nodes_list}; do
    echo "--- check node ${node} ---"

    security_profile_output=$(mktemp)
    az vm show -n "${node}" -g "${RESOURCE_GROUP}" -ojson | jq -r '.securityProfile' 1>"${security_profile_output}"

    echo "node ${node} security profile"
    cat "${security_profile_output}"
    if [[ $(< "${security_profile_output}") == "null" ]]; then
        echo "node ${node} security profile is null, check failed!"
        critical_check_result=1
        continue
    fi

    if property_check "${node}" "encryptionAtHost" "${encryptionathost}" "${security_profile_output}" ; then
        echo "property encryptionAtHost check passed."
    else
        echo "property encryptionAtHost check failed."
        critical_check_result=1
    fi

    if property_check "${node}" "securityType" "${security_type}" "${security_profile_output}" ; then
        echo "property securityType check passed."
    else
        echo "property securityType check failed."
        critical_check_result=1
    fi

    if property_check "${node}" "uefiSettings.secureBootEnabled" "${secure_boot}" "${security_profile_output}"; then
        echo "property secureBootEnabled check passed."
    else
        echo "property secureBootEnabled check failed."
        critical_check_result=1
    fi

    if property_check "${node}" "uefiSettings.vTpmEnabled" "${vtpm}" "${security_profile_output}"; then
        echo "property vTpmEnabled check passed."
    else
        echo "property vTpmEnabled check failed."
        critical_check_result=1
    fi
    rm -f "${security_profile_output}"
done
exit ${critical_check_result}
