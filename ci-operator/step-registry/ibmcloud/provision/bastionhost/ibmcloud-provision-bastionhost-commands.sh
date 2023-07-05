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
  echo "Try to login..."
  "${IBMCLOUD_CLI}" login -r ${region} --apikey @"${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
}

#####################################
##############Initialize#############
#####################################
ibmcloud_login
#create the bastion host based on the info (ibmcloud-provision-vpc ${SHARED_DIR}/customer_vpc_subnets.yaml), output ip info to ${SHARED_DIR}/bastion-info.yaml
cluster_name="${NAMESPACE}-${UNIQUE_HASH}"
bastion_info_yaml="${SHARED_DIR}/bastion-info.yaml"

bastion_name="${cluster_name}-bastion"
MACHINE_TYPE="bx2-2x8"
#The default coreos image value is gotten from
#imgProfile="fedora-coreos.*available.*amd64.*stable.*public"
#ibmcloud is images --visibility public --owner-type provider --resource-group-name Default | grep -i ${imgProfile}
IMAGE="ibm-fedora-coreos-36-stable-2"
workdir=${ARTIFACT_DIR}
bastion_ignition_file="${SHARED_DIR}/${cluster_name}-bastion.ign"

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, ignition-bastionhost step is required, abort." && exit 1
fi

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ ! -f "${VPC_CONFIG}" ]]; then
  echo "Fail to find of VPC info file ${VPC_CONFIG}, abort." && exit 1
fi
echo "Reading variables from ${VPC_CONFIG}..."
vpcName=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.vpcName')

resource_group=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.resourceGroupName')
echo "Using region: ${region}  resource_group: ${resource_group} vpc: ${vpcName}"

${IBMCLOUD_CLI} target -g ${resource_group}

subnet=$(${IBMCLOUD_CLI} is vpc ${vpcName} --show-attached --output JSON | jq -c -r '[.subnets[] | select(.name|test("control-plane")) | .name][0]')

if [ "${subnet}"X == X ]; then
  echo "ERROR" "Fail to get subnet of vpc ${vpcName}, abort" &&  exit 1
fi
echo "subnet: ${subnet}"
zone=$(${IBMCLOUD_CLI} is subnet ${subnet} --output JSON | jq -r '.zone.name')
echo "zone ${zone}"

sg=$(${IBMCLOUD_CLI} is vpc-sg ${vpcName} --output JSON | jq -r .id)
echo "sg:" $sg

#####################################
##########Create Bastion#############
#####################################
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --remote \"0.0.0.0/0\" --port-min=22 --port-max=22"
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --remote \"0.0.0.0/0\" --port-min=3128 --port-max=3129"
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound icmp --remote \"0.0.0.0/0\" --icmp-type 8 --icmp-code 0 "
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --remote \"0.0.0.0/0\" --port-min=5000 --port-max=5000"
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --remote \"0.0.0.0/0\" --port-min=6001 --port-max=6002"
run_command "${IBMCLOUD_CLI} is security-group-rule-add $sg inbound tcp --remote \"0.0.0.0/0\" --port-min=873 --port-max=873"

echo "Created bastion instance"
run_command "${IBMCLOUD_CLI} is instance-create ${bastion_name} ${vpcName} ${zone} ${MACHINE_TYPE} ${subnet} --image ${IMAGE} --user-data "@${bastion_ignition_file}" --output JSON"

sleep 300

insFile="${workdir}/${bastion_name}.json"
run_command "${IBMCLOUD_CLI} is instance ${bastion_name} --output JSON > ${insFile}"
echo "INFO" "Created bastion instance ${bastion_name} status: $(jq -r '.status' ${insFile})"
bastion_private_ip="$(jq -r '.network_interfaces[0].primary_ip.address' ${insFile})"

nic=$(jq -r '.network_interfaces[0].id' ${insFile})
fip="${cluster_name}-fip"
bastion_public_ip=$(${IBMCLOUD_CLI} is floating-ip-reserve ${fip} --nic-id $nic --output JSON | jq -r .address)

if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "ERROR" "Failed to find bastion's public and private IP!"
    exit 1
fi

run_command "${IBMCLOUD_CLI} is instance-network-interface-floating-ip-add ${bastion_name} ${nic} ${fip}"

#dump the info 
run_command "${IBMCLOUD_CLI} is instance-network-interface-floating-ips ${bastion_name} $nic"
run_command "${IBMCLOUD_CLI} is sg-rules $sg --vpc ${vpcName}"

#####################################
#########Save Bastion Info###########
#####################################

echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

cat > "${bastion_info_yaml}" << EOF
publicIpAddress: ${bastion_public_ip}
privateIpAddress: ${bastion_private_ip}
bastionHost: ${bastion_name}
vpcName: ${vpcName}
EOF

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"
# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" > "${SHARED_DIR}/proxyip"

