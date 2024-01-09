#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
  local CMD="$1"
  echo "Running Command: ${CMD}"
  eval "${CMD}"
}

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    echo "Try to login..." 
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function findTarget() {
    local allTargetsFile="$1" target_endpoint_url="$2" target_endpoint_fqdn

    target_endpoint_fqdn=$(get_fqdn_from_url "${target_endpoint_url}")
    cat "${allTargetsFile}" | jq -r --arg n "${target_endpoint_fqdn}" '.[] | select(.fully_qualified_domain_names[0] // "" | test($n)) | .crn'
}

function createEndpointGateway() {
    local vpcID="$1" sgID="$2" subnetID="$3" targetCRN="$4" vpeGatewayName="$5" ret log cmd
    log=$(mktemp)
    echo "ibmcloud is endpoint-gateway-delete ${vpeGatewayName} --vpc ${vpcID} -f || true" >>"${SHARED_DIR}/ibmcloud_remove_resources_by_cli.sh"
    cmd="ibmcloud is endpoint-gateway-create --vpc ${vpcID} --sg ${sgID} --new-reserved-ip '{\"subnet\":{\"id\": \"${subnetID}\"}}' --target ${targetCRN} --name ${vpeGatewayName}"
    echo "Command: $cmd"
    eval "$cmd" &> "${log}"; ret=$?
    cat "${log}"
    if [[ "$ret" != "0" ]] && grep -q "endpoint gateway already exists for this service" "${log}"; then
        echo "The endpoint gateway already exists for this service, ignore the error..."
        return 0
    fi
    waitingStatus ${vpeGatewayName};  ret=$?
    echo "${vpeGatewayName} waiting status: ${ret}"
    run_command "ibmcloud is endpoint-gateway ${vpeGatewayName}"

    if [[ "${ret}" != 0 ]]; then
        echo "ERROR: fail to create the endpoint gateway ${vpeGatewayName} on vpc"
        return 1
    fi
    return 0
}

function waitingStatus() {
    local endpoint=$1 status counter=0
    while [ $counter -lt 20 ]
    do 
        sleep 10
        counter=$(expr $counter + 1)
        status=$(ibmcloud is endpoint-gateway $endpoint --output JSON | jq -r ."lifecycle_state")
        if [[ "${status}" == "stable" ]]; then
            return 0
        fi
    done
    return 1
}

function get_fqdn_from_url() {
    local url="$1" tmp_fqdn
    tmp_fqdn=$(echo "${url#*://}")
    tmp_fqdn=$(echo "${tmp_fqdn%%/*}")
    tmp_fqdn=$(echo "${tmp_fqdn#*@}")
    echo "${tmp_fqdn%%:*}"
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}


ibmcloud_login
resource_group=$(cat "${SHARED_DIR}/ibmcloud_resource_group")
"${IBMCLOUD_CLI}" target -g ${resource_group}

DEFAULT_PRIVATE_ENDPOINTS=$(mktemp)
REGION="${LEASED_RESOURCE}"
cat > "${DEFAULT_PRIVATE_ENDPOINTS}" << EOF
{
    "IAM": "https://private.iam.cloud.ibm.com",
    "VPC": "https://${REGION}.private.iaas.cloud.ibm.com/v1",
    "ResourceController": "https://private.resource-controller.cloud.ibm.com",
    "ResourceManager": "https://private.resource-controller.cloud.ibm.com",
    "DNSServices": "https://api.private.dns-svcs.cloud.ibm.com/v1",
    "COS": "https://s3.direct.${REGION}.cloud-object-storage.appdomain.cloud",
    "GlobalSearch": "https://api.private.global-search-tagging.cloud.ibm.com",
    "GlobalTagging": "https://tags.private.global-search-tagging.cloud.ibm.com"
}
EOF
vpcName=$(<"${SHARED_DIR}/ibmcloud_vpc_name")
vpc_info_file=$(mktemp)
check_vpc "${vpcName}" "${vpc_info_file}" || exit 1
vpcID=$(cat "${vpc_info_file}" | jq -r '.vpc.id')
sgID=$(cat "${vpc_info_file}" | jq -r '.vpc.default_security_group.id')
subnetID=$(cat "${vpc_info_file}" | jq -r '.subnets[0].id')
clusterName="${NAMESPACE}-${UNIQUE_HASH}"
allTargetsFile=$(mktemp)
ibmcloud is endpoint-gateway-targets -q -output JSON > ${allTargetsFile} || exit 1
run_command "ibmcloud is security-group-rule-add ${sgID} inbound tcp --remote '0.0.0.0/0' --port-min=443 --port-max=443" || exit 1

srv_array=("IAM" "VPC" "ResourceController" "ResourceManager" "DNSServices" "COS" "GlobalSearch" "GlobalTagging")
for srv in "${srv_array[@]}"; do
    real_srv_endpoint_url=""
    eval srv_endpoint_url='$'SERVICE_ENDPOINT_${srv}
    if [[ -n "${srv_endpoint_url}" ]]; then
        echo "INFO: service ${srv} endpoint - ${srv_endpoint_url} is defined in ENV"
        if [[ "${srv_endpoint_url}" == "DEFAULT_ENDPOINT" ]]; then
            real_srv_endpoint_url=$(jq -r --arg s "${srv}" '.[$s] // ""' "${DEFAULT_PRIVATE_ENDPOINTS}")
            if [[ -z "${real_srv_endpoint_url}" ]]; then
                echo "ERROR: Did not get default private endpoint url!"
                exit 1
            else
                echo "INFO: the real endpoint url is ${real_srv_endpoint_url}"
            fi
        else
            real_srv_endpoint_url="${srv_endpoint_url}"
        fi
        target=$(findTarget "${allTargetsFile}" "${real_srv_endpoint_url}")
        if [[ -z "${target}" ]]; then
            echo "ERROR: Did not find out endpoint gateway target"
            exit 1
        fi
        echo "INFO: service ${srv} endpoint - ${real_srv_endpoint_url} gateway target is: ${target}"
        srv_lowercase=$(echo "${srv}" | tr '[:upper:]' '[:lower:]')
        vpeGatewayName="${clusterName}-${srv_lowercase}"
        echo "INFO: Going to create VPE gateway named ${vpeGatewayName}..."
        createEndpointGateway ${vpcID} ${sgID} ${subnetID} ${target} "${vpeGatewayName}" || exit 1
    fi
done
