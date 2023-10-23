#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# IBM Cloud CLI login
function ibmcloud_login {
    export IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_HOME=/output   
    region="${LEASED_RESOURCE}"
    export region
    echo "Try to login..." 
    "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

function create_resource_group() {
    local rg="$1"
    echo "create resource group ... ${rg}"
    "${IBMCLOUD_CLI}" resource group-create ${rg} || return 1
    "${IBMCLOUD_CLI}" target -g ${rg} || return 1
}

function getZoneSubnets() {
    local vpcName="$1" zone="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON | jq -r --arg z "${zone}" '.subnets[] | select(.zone.name==$z) | .name'
}

function getZoneAddressprefix() {
    local vpcName="$1" zone="$2"

    "${IBMCLOUD_CLI}" is vpc-address-prefixes ${vpcName} --output JSON | jq -c -r --arg z ${zone} '.[] | select(.zone.name==$z) | .cidr'
}

function getOneMoreCidr() {
    local cidr="$1"

    IFS='.' read -r -a cidr_num_array <<< "${cidr}"
    cidr_num_array[2]=$((${cidr_num_array[2]} + 1))    
    IFS=. ; echo "${cidr_num_array[*]}"
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

function create_vpc() {
    local preName="$1" vpcName="$2" resource_group="$3" region="$4"
    local zones zone_cidr zone_cidr_main subnetName

    # create vpc
    "${IBMCLOUD_CLI}" is vpc-create ${vpcName} --resource-group-name ${resource_group}

    waitAvailable "vpc" ${vpcName}
    
    # create subnets
    zones=("${region}-1" "${region}-2" "${region}-3")

    for zone in "${zones[@]}"; do
        zone_cidr=$(getZoneAddressprefix "${vpcName}" "${zone}")
        zone_cidr_main="${zone_cidr%/*}"
        subnetName="${preName}-control-plane-${zone}"
        "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpcName} --ipv4-cidr-block "${zone_cidr_main}/24"
        waitAvailable "subnet" ${subnetName}
    done

    for zone in "${zones[@]}"; do
        zone_cidr=$(getZoneAddressprefix "${vpcName}" "${zone}")
        zone_cidr_main=$(getOneMoreCidr "${zone_cidr%/*}")
        subnetName="${preName}-compute-${zone}"
        "${IBMCLOUD_CLI}" is subnet-create ${subnetName} ${vpcName} --ipv4-cidr-block "${zone_cidr_main}/24"
        waitAvailable "subnet" ${subnetName}
    done
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}

function string2arr() {
    # parameter:
    # $1: a string with seperator. Note: each item by seperator can not include whitespace
    # $2: seperator, by default, it is ,
    local intput_string="$1" seperator="$2" output_array

    if [[ -z "$seperator" ]]; then
        seperator=","
    fi

    IFS="$seperator" read -r -a output_array <<< "${intput_string}"
    echo "${output_array[@]}"
}

function getAddressPre() {
    local vpc_info_file="$1"
    local ip ips
    ip=$(cat ${vpc_info_file} | jq -c -r .address_prefixes[0].cidr)
    IFS="." read -ra ips <<< "${ip}"
    echo "${ips[0]}.${ips[1]}.0.0/16"
}

function create_zone_public_gateway() {
    local gateName="$1" vpcName="$2" zone="$3"

    "${IBMCLOUD_CLI}" is public-gateway-create ${gateName} ${vpcName} ${zone} || return 1
}

function attach_public_gateway_to_subnet() {
    local subnetName="$1" vpcName="$2" pgwName="$3"

    "${IBMCLOUD_CLI}" is subnet-update ${subnetName} --vpc ${vpcName} --pgw ${pgwName} || return 1
}

ibmcloud_login

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

resource_group="${CLUSTER_NAME}-rg"

create_resource_group ${resource_group}
echo "${resource_group}" > "${SHARED_DIR}/ibmcloud_resource_group"

echo "Create VPC..."
vpc_name="${CLUSTER_NAME}-vpc"
echo "${vpc_name}" > "${SHARED_DIR}/ibmcloud_vpc_name"
create_vpc "${CLUSTER_NAME}" "${vpc_name}" "${resource_group}" "${region}" 

vpc_info_file="${ARTIFACT_DIR}/vpc_info"
check_vpc "${vpc_name}" "${vpc_info_file}"

vpcAddressPre=$(getAddressPre ${vpc_info_file})

if [[ "${RESTRICTED_NETWORK}" = "yes" ]]; then
    echo "[WARN] Skip creating public gateway to create disconnected network"
else
    zones=("${region}-1" "${region}-2" "${region}-3")
    for zone in "${zones[@]}"; do
        echo "Creating public gateway in ${zone}..."
        public_gateway_name="${CLUSTER_NAME}-gateway-${zone}"
        create_zone_public_gateway "${public_gateway_name}" "${vpc_name}" "$zone"
        for subnet in $(cat "${vpc_info_file}" | jq -r --arg z "${zone}" '.subnets[] | select(.zone.name==$z) | .name'); do
            echo "Attaching public gateway - ${public_gateway_name} to subnet - ${subnet}..."
            attach_public_gateway_to_subnet "${subnet}" "${vpc_name}" "${public_gateway_name}"
        done
    done
fi
workdir="$(mktemp -d)"
cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("control-plane")) | .name]' | yq-go r -P - >${workdir}/controlPlaneSubnets.yaml
cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("compute")) | .name]' | yq-go r -P - >${workdir}/computerSubnets.yaml

cat > "${SHARED_DIR}/customer_vpc_subnets.yaml" << EOF
platform:
  ibmcloud:
    resourceGroupName: ${resource_group}
    networkResourceGroupName: ${resource_group}
    vpcName: ${vpc_name}
networking:
  machineNetwork:
  - cidr: ${vpcAddressPre}     
EOF
yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.controlPlaneSubnets' -f ${workdir}/controlPlaneSubnets.yaml
yq-go w -i "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.ibmcloud.computeSubnets' -f ${workdir}/computerSubnets.yaml
rm -rfd ${workdir}
cat ${SHARED_DIR}/customer_vpc_subnets.yaml
