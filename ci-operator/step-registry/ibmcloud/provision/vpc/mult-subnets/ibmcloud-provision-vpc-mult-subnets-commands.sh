#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MORE_SUBNETS_COUNT=$((EXTRA_SUBNETS_NUMBER))
#15 is the max number of of ALB, so just create more subnets on vpc, do not use them when create cluster. https://cloud.ibm.com/docs/vpc?topic=vpc-load-balancer-faqs#max-number-subnets-alb

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

function create_subnets() {
    local preName="$1" vpc_name="$2" resource_group="$3" region="$4"
    local zones prefix pgwName zid subnetCount subnetName
 
    # create subnets
    zones=("${region}-1" "${region}-2" "${region}-3")
    prefix="${region}-"
    subnetCount=$((MORE_SUBNETS_COUNT / 3))
    for zone in "${zones[@]}"; do
        pgwName=$(ibmcloud is subnets | grep control-plane-${zone} | awk '{print $7}')
    
        zid=${zone#$prefix}
        for id in $(seq 1 ${subnetCount}); do
            subnetName="${preName}-control-plane-${zid}-${id}"
            "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpc_name} --zone ${zone} --ipv4-address-count 8 --resource-group-name ${resource_group} --pgw ${pgwName} || return 1
            waitAvailable "subnet" ${subnetName}
            echo "succeed created subnet ${zid}-${id} in ${zone}================================"
        done
    done
    r_subnetCount=$((MORE_SUBNETS_COUNT % 3))
    echo "r_subnetCount: $r_subnetCount"
    if [[ ${r_subnetCount} -gt 0 ]]; then
        for id in $(seq 1 ${r_subnetCount}); do
            subnetName="${preName}-control-plane-${id}"
            "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpc_name} --zone ${zone} --ipv4-address-count 8 --resource-group-name ${resource_group} --pgw ${pgwName} || return 1
            waitAvailable "subnet" ${subnetName}
            echo "succeed created subnet ${id} in ${zone}================================"
        done
    fi

    echo "succeed created subnet..."
    "${IBMCLOUD_CLI}" is subnets
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}

ibmcloud_login

echo "MORE_SUBNETS_COUNT: ${MORE_SUBNETS_COUNT:-}"
echo "Try to add more subnets: ${MORE_SUBNETS_COUNT:-} ..."

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

create_subnets "${CLUSTER_NAME}" "${vpc_name}" "${resource_group}" "${region}" 

vpc_info_file="${ARTIFACT_DIR}/vpc_info"
check_vpc "${vpc_name}" "${vpc_info_file}"

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
