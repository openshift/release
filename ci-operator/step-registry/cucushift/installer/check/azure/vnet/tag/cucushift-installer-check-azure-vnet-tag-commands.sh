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

INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)

rg_file="${SHARED_DIR}/resourcegroup"
if [ -f "${rg_file}" ]; then
    RESOURCE_GROUP=$(cat "${rg_file}")
else
    echo "Did not findd an provisoned empty resource group"
    exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

critical_check_result=0
#nsg rule 'apiserver_in' check
ocp_minor_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)
if (( ${ocp_minor_version} < 15 )); then
    echo "Shared Tags on vnet checking is only applicable on 4.15+, skip the check!"
    exit 0
else
    echo "Checking that shared tags are added on existing vnet"
    vnet_list_file=$(mktemp)
    expected_shared_tags="\"kubernetes.io_cluster.${INFRA_ID}\": \"shared\""
    vnet_id=$(az network vnet list -g ${RESOURCE_GROUP} --query "[].id" -otsv)
    echo "tags on vnet:"
    az tag list --resource-id "${vnet_id}" --query 'properties.tags' | tee ${vnet_list_file}

    echo "expected shared tags: ${expected_shared_tags}"
    if grep -Fq "${expected_shared_tags}" ${vnet_list_file}; then
        echo "INFO: Found shared tags ${expected_shared_tags} on vnet ${vnet_id}"
    else
        echo "ERROR: Not found shared tags ${expected_shared_tags} on vnet ${vnet_id}"
        critical_check_result=1
    fi

    if [[ ! -z "${AZURE_VNET_TAGS}" ]]; then
        echo "check custom tags ${AZURE_VNET_TAGS} are not overriden"
        for tag in ${AZURE_VNET_TAGS}; do
            tag_content=$(echo $tag | awk -F'=' '{printf "\"%s\": \"%s\"",$1, $2}')
            echo "expected custom tag: ${tag_content}"
            if grep -Fq "${tag_content}" ${vnet_list_file}; then
                echo "INFO: Found shared tags ${tag_content} on vnet ${vnet_id}"
            else
                echo "ERROR: Not found shared tags ${tag_content} on vnet ${vnet_id}"
                critical_check_result=1
            fi
        done
    fi
fi

exit ${critical_check_result}
