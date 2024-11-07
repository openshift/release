#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

extra_subnets_count=$((EXTRA_SUBNETS_NUMBER))
#15 is the max number of of ALB, so just create more subnets on vpc, do not use them when create cluster. https://cloud.ibm.com/docs/vpc?topic=vpc-load-balancer-faqs#max-number-subnets-alb

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    "${IBMCLOUD_CLI}" config --check-version=false
    "${IBMCLOUD_CLI}" plugin list
    echo "Try to login..." 
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function waitAvailable() {
    local retries=15  try=0 
    local type="$1" name="$2"
    while [ "$(${IBMCLOUD_CLI} is ${type} ${name} --output JSON | jq -r '.status')" != "available" ] && [ $try -lt $retries ]; do
        echo "The ${name} is not available, waiting..."
        sleep 10
        try=$(expr $try + 1)
    done

    if [ X"$try" == X"$retries" ]; then
        echo "Fail to get available ${type} - ${name}"
        "${IBMCLOUD_CLI}" is ${type} ${name} --output JSON
        return 1
    fi   
}

function createSubnet() {
    local subnetPreName="$1" vpcName="$2" zone="$3" id="$4"
    local subnetName pgwName
    pgwName=$(ibmcloud is subnets | grep ${subnetPreName}-${zone} | awk '{print $7}')
    subnetName="${subnetPreName}-${id}"
    "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpcName} --pgw ${pgwName} --ipv4-address-count 16 --zone ${zone}
    waitAvailable "subnet" ${subnetName}
}

function create_subnets() {
    local preName="$1" vpcName="$2" region="$3" subnetCount=$4
    local zones pgwName id

    zones=("${region}-1" "${region}-2" "${region}-3")
    id=0
    while [[ $id -lt $subnetCount ]]; do
        for zone in "${zones[@]}"; do
            createSubnet "${preName}-control-plane" "${vpcName}" "${zone}" "${id}"            
            ((id++))
            [[ $id -eq $subnetCount ]] && return
        done

        for zone in "${zones[@]}"; do
            createSubnet "${preName}-compute" "${vpcName}" "${zone}" "${id}"
            ((id++))
            [[ $id -eq $subnetCount ]] && return     
        done
    done
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2" expSubnetNum="$3"
    local num
    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
    num=$("${IBMCLOUD_CLI}" is subnets  --output JSON | jq '. | length')
    echo "created ${num} subnets in the vpc."
    if [[ ${num} -ne $((expSubnetNum + 6)) ]]; then
        echo "fail to created the extra expected subnets $expSubnetNum"
        echo "created subnet..."
        "${IBMCLOUD_CLI}" is subnets
        return 1
    else
        echo "created extra $expSubnetNum subnets successfully."
    fi
}

ibmcloud_login

echo "extra_subnets_count: ${extra_subnets_count:-}"
echo "Try to add more subnets: ${extra_subnets_count:-} ..."

rg_file="${SHARED_DIR}/ibmcloud_resource_group"
if [ -f "${rg_file}" ]; then
    resource_group=$(cat "${rg_file}")
else
    echo "Did not found a provisoned resource group"
    exit 1
fi
"${IBMCLOUD_CLI}" target -g ${resource_group}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
vpc_name=$(cat "${SHARED_DIR}/ibmcloud_vpc_name")
set -x
create_subnets "${CLUSTER_NAME}" "${vpc_name}" "${region}" ${extra_subnets_count}
set +x
vpc_info_file="${ARTIFACT_DIR}/vpc_info"
check_vpc "${vpc_name}" "${vpc_info_file}" ${extra_subnets_count}

if [[ "${USED_IN_CLUSTER}" = "yes" ]]; then
    echo "The extra subnets used in the cluster, update customer_vpc_subnets.yaml"
    workdir="$(mktemp -d)"
    cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("control-plane")) | .name]' | yq-go r -P - >${workdir}/controlPlaneSubnets.yaml
    cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("compute")) | .name]' | yq-go r -P - >${workdir}/computerSubnets.yaml

    yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.controlPlaneSubnets' -f ${workdir}/controlPlaneSubnets.yaml
    yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.computeSubnets' -f ${workdir}/computerSubnets.yaml
    rm -rfd ${workdir}
else
    echo "The extra subnets not used in the cluster, skip update customer_vpc_subnets.yaml"
fi

echo "Succeed to create subnets..."
cat ${SHARED_DIR}/customer_vpc_subnets.yaml
