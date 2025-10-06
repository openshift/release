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
    local vpcID="$1" sgID="$2" subnetID="$3" targetCRN="$4" vpeGatewayName="$5" ret log cmd counter=0
    log=$(mktemp)
    echo "ibmcloud is endpoint-gateway-delete ${vpeGatewayName} --vpc ${vpcID} -f || true" >>"${SHARED_DIR}/ibmcloud_remove_resources_by_cli.sh"
    cmd="ibmcloud is endpoint-gateway-create --vpc ${vpcID} --sg ${sgID} --new-reserved-ip '{\"subnet\":{\"id\": \"${subnetID}\"}}' --target ${targetCRN} --name ${vpeGatewayName}"
    echo "Command: $cmd"
    while [ $counter -lt 5 ]
    do
        counter=$(expr $counter + 1)
        eval "$cmd" &> "${log}"; ret=$?
        cat "${log}"
        if [[ "$ret" == 0 ]]; then
            echo "Successfully created ${vpeGatewayName}."
            break # Exit loop on success
        else
            if grep -q "endpoint gateway already exists for this service" "${log}"; then
                echo "The endpoint gateway already exists for this service, treating as success..."
                ret=0 # Override exit status to 0 to proceed
                break
            fi
            echo "Attempt ${counter} of 5 failed. Retrying in 10 seconds..."
            sleep 10
        fi
    done

    # Cleanup temporary log file
    rm -f "${log}"
    
    #check the endpoint-gateway status when created or has an existed
    echo "Waiting for ${vpeGatewayName} to become available..."
    waitingStatus "${vpeGatewayName}" || {
        echo "ERROR: The created endpoint gateway ${vpeGatewayName} status is not available."
        run_command "ibmcloud is endpoint-gateway ${vpeGatewayName}"
        return 1
    }
    echo "Successfully verified ${vpeGatewayName} status."
    run_command "ibmcloud is endpoint-gateway ${vpeGatewayName}"
    return 0    
}

function waitingStatus() {
    local endpoint=$1 status counter=0
    while [ $counter -lt 30 ]
    do 
        sleep 10
        counter=$(expr $counter + 1)
        status=$(ibmcloud is endpoint-gateway $endpoint --output JSON | jq -r ."lifecycle_state")
		rc="$?"
        if [[ "${status}" == "stable" ]]; then
            return 0
        elif [[ "$rc" != "0" ]]; then ## fail to get the status, directly exit 1
            return 1
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

DEFAULT_PRIVATE_ENDPOINTS="${SHARED_DIR}/eps_default.json"
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
    "GlobalTagging": "https://tags.private.global-search-tagging.cloud.ibm.com",
    "COSConfig": "https://config.direct.cloud-object-storage.cloud.ibm.com/v1",
    "GlobalCatalog": "https://private.globalcatalog.cloud.ibm.com",
    "KeyProtect": "https://private.${REGION}.kms.cloud.ibm.com",
    "HyperProtect": "https://api.private.${REGION}.hs-crypto.cloud.ibm.com"
}
EOF
vpcName=$(<"${SHARED_DIR}/ibmcloud_vpc_name")
vpc_info_file=$(mktemp)
check_vpc "${vpcName}" "${vpc_info_file}" || exit 1
vpcID=$(cat "${vpc_info_file}" | jq -r '.vpc.id')
sgID=$(cat "${vpc_info_file}" | jq -r '.vpc.default_security_group.id')
subnetID=$(cat "${vpc_info_file}" | jq -r '.subnets[0].id')
clusterName="${NAMESPACE}-${UNIQUE_HASH}"
allTargetsFile="${ARTIFACT_DIR}/ep_targets.json"
ibmcloud is endpoint-gateway-targets -q -output JSON > ${allTargetsFile} || exit 1
run_command "ibmcloud is security-group-rule-add ${sgID} inbound tcp --remote '0.0.0.0/0' --port-min=443 --port-max=443" || exit 1

srv_array=("IAM" "VPC" "ResourceController" "ResourceManager" "DNSServices" "COS" "GlobalSearch" "GlobalTagging" "KeyProtect" "HyperProtect" "COSConfig" "GlobalCatalog")
# "ResourceController" "ResourceManager"  just can be has one, otherwise will got "An endpoint gateway already exists for this service"

if  (( RANDOM % 2 )); then
    unset 'srv_array[2]'
else
    unset 'srv_array[3]'
fi
srv_array=("${srv_array[@]}")
echo "serives:" "${srv_array[@]}"

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
            echo "ERROR: Did not find out endpoint gateway target of $srv"
            exit 1
        fi
        echo "INFO: service ${srv} endpoint - ${real_srv_endpoint_url} gateway target is: ${target}"
        srv_lowercase=$(echo "${srv}" | tr '[:upper:]' '[:lower:]')
        vpeGatewayName="${clusterName}-${srv_lowercase}"
        echo "INFO: Going to create VPE gateway named ${vpeGatewayName}..."
        createEndpointGateway ${vpcID} ${sgID} ${subnetID} ${target} "${vpeGatewayName}" || exit 1
    fi
done
