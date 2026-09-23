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

function add_lb_record() {
    local name="$1"
    local target="$2"
    local record_type="$3"
    local out="$4"
    if [ ! -e "$out" ]; then
        echo -n '[]' > "$out"
    fi
    cat <<< "$(jq --arg n "${name}" --arg t "${target}" --arg r "${record_type}" '. += [{"name": $n, "target": $t, "record_type": $r}]' "$out")" > "$out"
}

function get_lb_ip() {

    local lb_name=$1 type=$2 port=$3 out=$4

    frontendipconfig_id=$(az network lb show -n ${lb_name} -g ${RESOURCE_GROUP} -ojson | jq -r ".loadBalancingRules[] | select(.frontendPort == ${port}) | .frontendIPConfiguration.id")
    frontendipconfig_name=${frontendipconfig_id##*/}

    if [[ "${type}" == "External" ]]; then
        frontendpublicip_id=$(az network lb frontend-ip show -n ${frontendipconfig_name} --lb-name ${lb_name} -g ${RESOURCE_GROUP} --query "publicIPAddress.id" -otsv)
        lb_ip=$(az network public-ip show --ids ${frontendpublicip_id} --query 'ipAddress' -otsv)
        echo "LB rule's(port: ${port}) frontend public IP in public LB: ${lb_ip}"
    elif [[ "${type}" == "Internal" ]]; then
        lb_ip=$(az network lb frontend-ip show -n ${frontendipconfig_name} --lb-name ${lb_name} -g ${RESOURCE_GROUP} --query "privateIPAddress" -otsv)
        echo "LB rule's(port: ${port}) frontend private IP in internal LB: ${lb_ip}"
    fi
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

if [[ -z "${BASE_DOMAIN}" ]]; then
    echo "ERROR: env 'BASE_DOMAIN' is not set, could not be empty, please check!"
    exit 1
fi

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
INFRA_ID=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
CLUSTER_NAME=$(yq-go r "${INSTALL_CONFIG}" 'metadata.name')
RESOURCE_GROUP=$(yq-go r "${INSTALL_CONFIG}" 'platform.azure.resourceGroupName')
if [[ -z "${RESOURCE_GROUP}" ]]; then
    RESOURCE_GROUP="${INFRA_ID}-rg"
fi

PUBLISH=$(yq-go r "${INSTALL_CONFIG}" 'publish')
if [[ "${PUBLISH}" != "Mixed" ]]; then
    echo "This step used to configure custom dns for mixed publish strategy!"
    exit 1
fi
apiserver_config="$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.apiserver')"
apiserver_publish=${apiserver_config:-"External"}
ingress_config="$(yq-go r "${INSTALL_CONFIG}" 'operatorPublishingStrategy.ingress')"
ingress_publish=${ingress_config:-"External"}

# api server
if [[ "${apiserver_publish}" == "External" ]]; then
    get_lb_ip "${INFRA_ID}" "External" "6443" "${ARTIFACT_DIR}/apiserver_lb_ip"
    api_lb_ip="$(< "${ARTIFACT_DIR}/apiserver_lb_ip")"
    if [[ -z "${api_lb_ip}" ]]; then
        echo "Unable to get api server rule's frontend IP from public load balancer!"
        exit 1
    fi
    add_lb_record "api.${CLUSTER_NAME}.${BASE_DOMAIN}" "${api_lb_ip}" "A" "${SHARED_DIR}/public_custom_dns.json"
elif [[ "${apiserver_publish}" == "Internal" ]]; then
    get_lb_ip "${INFRA_ID}-internal" "Internal" "6443" "${ARTIFACT_DIR}/apiserver_lb_ip"
    api_lb_ip="$(< "${ARTIFACT_DIR}/apiserver_lb_ip")"
    if [[ -z "${api_lb_ip}" ]]; then
        echo "Unable to get api server rule's frontend IP from internal load balancer!"
        exit 1
    fi
    echo "api.${CLUSTER_NAME}.${BASE_DOMAIN} ${api_lb_ip}" >> "${SHARED_DIR}/custom_dns"
else
    echo "Unsupported api server publish strategy ${apiserver_publish}!"
    exit 1
fi

# ingress
if [[ "${ingress_publish}" == "External" ]]; then
    get_lb_ip "${INFRA_ID}" "External" "443" "${ARTIFACT_DIR}/ingress_lb_ip"
    ingress_lb_ip=$(<"${ARTIFACT_DIR}/ingress_lb_ip")
    if [[ -z "${ingress_lb_ip}" ]]; then
        echo "Unable to get ingress rule's frontend IP from public load balancer!"
        exit 1
    fi
    add_lb_record "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}" "${ingress_lb_ip}" "A" "${SHARED_DIR}/public_custom_dns.json"
elif [[ "${ingress_publish}" == "Internal" ]]; then
    get_lb_ip "${INFRA_ID}-internal" "Internal" "443" "${ARTIFACT_DIR}/ingress_lb_ip"
    ingress_lb_ip=$(<"${ARTIFACT_DIR}/ingress_lb_ip")
    if [[ -z "${ingress_lb_ip}" ]]; then
        echo "Unable to get ingress rule's frontend IP from internal load balancer!"
        exit 1
    fi
    echo "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN} ${ingress_lb_ip}" >> "${SHARED_DIR}/custom_dns"
else
    echo "Unsupported ingress publish strategy ${ingress_publish}!"
    exit 1
fi

if [[ -f "${SHARED_DIR}"/custom_dns ]]; then
    echo "custom_dns:"
    cat "${SHARED_DIR}/custom_dns"
fi

if [[ -f "${SHARED_DIR}"/public_custom_dns.json ]]; then
    echo "public_custom_dns.json:"
    cat "${SHARED_DIR}"/public_custom_dns.json
fi
