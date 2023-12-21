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

function validation_infrastructure() {
    local action=$1
    local patch=$2
    local error=$3

    catch_res_file=$(mktemp)
    if [[ "${action}" == "replace" ]]; then
        oc patch infrastructure cluster -p "[{\"op\":\"replace\",\"path\":\"/status/platformStatus/azure/resourceTags\",\"value\": [${patch}]}]" --type json --subresource status &> "${catch_res_file}" || true
    elif [[ "${action}" == "remove" ]]; then 
        oc patch infrastructure cluster --type='json' -p '[{"op": "remove", "path": "/status/platformStatus/azure/resourceTags"}]' --subresource status &> "${catch_res_file}" || true
    fi

    if grep -q "${error}" ${catch_res_file}; then
        echo "INFO: catch the expected error"
    else
        echo "ERROR: fail to catch expected error, actual error: "
        cat "${catch_res_file}"
        check_result=1
    fi

    rm -rf ${catch_res_file}
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
BASE_DOMAIN=$(yq-go r "${INSTALL_CONFIG}" 'baseDomain')
BASE_DOMAIN_RG=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.baseDomainResourceGroupName')
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
PUBLISH_STRATEGY=$(yq-go r "${INSTALL_CONFIG}" 'publish')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

check_result=0

ocp_owned_key="kubernetes.io_cluster.${INFRA_ID}"
ocp_owned_value="owned"
user_tags_from_config=$(yq-go r ${INSTALL_CONFIG} 'platform.azure.userTags' -j | sed 's/false/"false"/g' | jq -c)
echo "user_tags_from_config: ${user_tags_from_config}"
#append OCP owned tag
expected_user_tags=$(echo "${user_tags_from_config}" | jq -c -S ". += {\"${ocp_owned_key}\":\"${ocp_owned_value}\"}")
echo "expected_user_tags: ${expected_user_tags}"

#check tags on resource created in resource group
resource_info_file=$(mktemp)
echo "All resrouces created in cluster resource group ${RESOURCE_GROUP}:"
az resource list -g ${RESOURCE_GROUP} --query '[].{type:type, name:name, tags:tags}' -ojson | tee ${resource_info_file}
readarray -t res_info_array < <(jq -c '.[]' ${resource_info_file})
echo -e "\n************ Checking resources tags created in resource group ${RESOURCE_GROUP} ************ "
for item in "${res_info_array[@]}"; do
    res_type=$(echo ${item} | jq -r -c '.type')
    res_name=$(echo ${item} | jq -r -c '.name')
    res_tags=$(echo ${item} | jq -r -c -S '.tags')

    echo "(*) check tags on resource ${res_type} ${res_name}"
    echo "tags on ${res_name}: ${res_tags}"

    if [[ "${res_type}" == "Microsoft.Network/publicIPAddresses" ]] && [[ "${res_tags}" =~ k8s-azure-cluster-name ]]; then
        echo "WARN: app public ip address is not tagged with openshift or user tags since it is not created by openshift core operator! Skip the check..."
        continue
    fi

    if [[ "${res_type}" == "Microsoft.Compute/disks" ]] && [[ "${res_tags}" =~ kubernetes.io-created-for-pv-name ]]; then
        echo "WARN: here is limitation, user-defined tags for PV volumnes cannot be updated! Skip the check..."
        continue
    fi

    if [[ "${res_tags}" != "${expected_user_tags}" ]]; then
        echo "ERROR: tags attached on resource ${res_name} don't match with expected tags list!"
        check_result=1
    else
        echo "INFO: tags attached on resource ${res_name} match with expected tags list!"
    fi
done

#check tags on resource group
echo -e "\n************ Checking tags on resource group ${RESOURCE_GROUP} ************ "
rg_tags=$(az group show --name ${RESOURCE_GROUP} --query tags -ojson | jq -c )
rg_tags=$(echo "${rg_tags}" | jq -c -S 'del(.openshift_creationDate)')
echo "tags on ${RESOURCE_GROUP}: ${rg_tags}"
if [[ "${rg_tags}" != "${expected_user_tags}" ]]; then
    echo "ERROR: tags attached on resource group ${RESOURCE_GROUP} don't match with expected tags list!"
    check_result=1
else
    echo "INFO: tags attached on resource group ${RESOURCE_GROUP} match with expected tags list!"
fi

#check tags on public dns records 
if [[ -z "${PUBLISH_STRATEGY}" ]] || [[ "${PUBLISH_STRATEGY}" == "External" ]]; then
    echo -e "\n************ Checking tags on dns records in public zone ************ "
    echo "(*) checking tags on app dns record in public zone"
    app_dns_tags=$(az network dns record-set a show -n "*.apps.${CLUSTER_NAME}" --resource-group "${BASE_DOMAIN_RG}" --zone-name "${BASE_DOMAIN}" | jq -r -c -S ".metadata")
    echo "tags on app dns record: ${app_dns_tags}"
    if [[ "${app_dns_tags}" != "${expected_user_tags}" ]]; then
        echo "ERROR: tags attached on app dns record *.apps.${CLUSTER_NAME} in public zone don't match with expected tags list!"
        check_result=1
    else
        echo "INFO: tags attached on app dns record *.apps.${CLUSTER_NAME} in public zone match with expected tags list!"
    fi

    echo "(*) checking tags on api dns record in public zone"
    api_dns_tags=$(az network dns record-set cname show -n "api.${CLUSTER_NAME}" --resource-group "${BASE_DOMAIN_RG}" --zone-name "${BASE_DOMAIN}" | jq -r -c -S ".metadata")
    echo "tags on api dns record: ${app_dns_tags}"
    if [[ "${api_dns_tags}" != "${expected_user_tags}" ]]; then
        echo "ERROR: tags attached on api dns record api.${CLUSTER_NAME} in public zone don't match with expected tags list!"
        check_result=1
    else
        echo "INFO: tags attached on app dns record api.${CLUSTER_NAME} in public zone match with expected tags list!"
    fi
fi

#check tags on private dns records
echo -e "\n************ Checking tags on dns records in private zone ************ "
echo "(*) checking tags on api-int dns record in private zone"
api_int_private_dns_tags=$(az network private-dns record-set a show -n "api-int" --resource-group "${RESOURCE_GROUP}" --zone-name "${CLUSTER_NAME}.${BASE_DOMAIN}" | jq -r -c -S ".metadata")
echo "tags on api-int private dns record: ${api_int_private_dns_tags}"
if [[ "${api_int_private_dns_tags}" != "${expected_user_tags}" ]]; then
    echo "ERROR: tags attached on api-int private dns record don't match with expected tags list!"
    check_result=1
else
    echo "INFO: tags attached on api-int private dns record match with expected tags list!"
fi

echo "(*) checking tags on *.apps dns record in private zone"
apps_private_dns_tags=$(az network private-dns record-set a show -n "*.apps" --resource-group "${RESOURCE_GROUP}" --zone-name "${CLUSTER_NAME}.${BASE_DOMAIN}" | jq -r -c -S ".metadata")
echo "tags on *.apps private dns record: ${apps_private_dns_tags}"
if [[ "${apps_private_dns_tags}" != "${expected_user_tags}" ]]; then
    echo "ERROR: tags attached on *.apps private dns record don't match with expected tags list!"
    check_result=1
else
    echo "INFO: tags attached on *.apps private dns record match with expected tags list!"
fi

echo "(*) checking tags on api dns record in private zone"
api_private_dns_tags=$(az network private-dns record-set a show -n "api" --resource-group "${RESOURCE_GROUP}" --zone-name "${CLUSTER_NAME}.${BASE_DOMAIN}" | jq -r -c -S ".metadata")
echo "tags on api private dns record: ${api_private_dns_tags}"
if [[ "${api_private_dns_tags}" != "${expected_user_tags}" ]]; then
    echo "ERROR: tags attached on api private dns record don't match with expected tags list!"
    check_result=1
else
    echo "INFO: tags attached on api private dns record match with expected tags list!"
fi

# check tags in resource infrastruture on cluster
echo -e "\n************ Check tags in object infrastruture on cluster ************ "
infra_tags=$(oc get infrastructure cluster -ojson | jq -r -c '.status.platformStatus.azure.resourceTags[]')
infra_tags_json="{}"
for item in ${infra_tags}; do
    key=$(echo $item | jq -c -r '.key')
    value=$(echo $item | jq -c -r '.value')
    infra_tags_json=$(echo $infra_tags_json | jq -c -S ". +={\"${key}\":\"${value}\"}")
done
echo ".status.platformStatus.azure.resourceTags in reousrce infrastruture: ${infra_tags_json}"
if [[ "${infra_tags_json}" != "${user_tags_from_config}" ]]; then
    echo "ERROR: user tags in resource infrastruture on cluster don't match with expected tags list!"
    check_result=1
else
    echo "INFO: user tags in resource infrastruture on cluster match with expected tags list!"
fi

# validate tags checking in infrastruture on cluster
echo -e "\n************ validate invalid tags setting in infrastruture on cluster ************"
catch_res_file=$(mktemp)
patch_1='{"key": "key1", "value": ""}'
error_1="value in body should be at least 1 chars long" 
echo "(*) tag value check, should be at least 1 chars long"
validation_infrastructure "replace" "${patch_1}" "${error_1}"

patch_2='{"key": "", "value": "value1"}'
error_2="key in body should be at least 1 chars long"
echo "(*) tag key check, should be at least 1 chars long"
validation_infrastructure "replace" "${patch_2}" "${error_2}"

patch_3='{"key": "key@x", "value": "value@x"}'
error_3="key in body should match '\^\[a-zA-Z\](\[0-9A-Za-z_.-\]\*\[0-9A-Za-z_\])?\\$'"
echo "(*) tag key check, should match '^[a-zA-Z]([0-9A-Za-z_.-]*[0-9A-Za-z_])?$'"
validation_infrastructure "replace" "${patch_3}" "${error_3}"

patch_4='{"key": "key1", "value": "[value]"}'
error_4="value in body should match '\^\[0-9A-Za-z_.=+-\@\]+\\$'"
echo "(*) tag value check, should match '^[0-9A-Za-z_.=+-@]+$'"
validation_infrastructure "replace" "${patch_4}" "${error_4}"

patch_5='{"key": "DZPJyCpx0NEChNvfgFPr1eK5I53w3htKkQglqg5BhjhJTZ6Az3KN8teTbg6N6w2S8giisJWtSPeiHOJexDZMW5un9LYT0z7nNsnTF7ZcqNHbOiBGLMB1bRAXWHAKtuPD7", "value": "value"}'
error_5="key: Too long: may not be longer than 128"
echo "(*) tag key check, max length is 128"
validation_infrastructure "replace" "${patch_5}" "${error_5}"

patch_6='{"key": "key1", "value": "0zNABZ1SqkJliGZju6AWViRh4RD3A07Fe8lUGdEiLW28NUyKGyVzNgqCbIl1tIw86ABd2Vh0WF8VyTLHktqhm71gVc9A5A3WQ3PlgFAHlcZh9w0VvfDrlCqOJowZMx8HJk8EpBNdC0KhDG3lmjPoBjIHj4If22Ip3nNL1r5HM8lUKc01l0aUHPuPj7kJG6MJ4wmxt0zMSBgEVebVbOqLmDX6TBj2EmBUsGSHvt8KGL2HHdpqKwUqUMPvNl6eJIAuj"}'
error_6="value: Too long: may not be longer than 256"
echo "(*) tag value check, max length is 256"
validation_infrastructure "replace" "${patch_6}" "${error_6}"

patch_7="empty"
error_7="resourceTags may only be configured during installation"
echo "(*) tag could not be removed"
validation_infrastructure "remove" "${patch_7}" "${error_7}"

patch_8='{"key": "k1", "value": "v1"},{"key": "k2", "value": "v2"},{"key": "k3", "value": "v3"},{"key": "k4", "value": "v4"},{"key": "k5", "value": "v5"},{"key": "k6", "value": "v6"},{"key": "k7", "value": "v7"},{"key": "k8", "value": "v8"},{"key": "k9", "value": "v9"},{"key": "k10", "value": "v10"},{"key": "k11", "value": "v11"}'
error_8="Too many: 11: must have at most 10 items"
echo "(*) max tags number is 11"
validation_infrastructure "replace" "${patch_8}" "${error_8}"

if (( ${check_result} == 1 )); then
    echo "user tags check failed!"
    [[ "${EXIT_ON_INSTALLER_CHECK_FAIL}" == "yes" ]] && exit 1
fi

exit 0
