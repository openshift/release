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
  "${IBMCLOUD_CLI}" plugin list
}

function check_vpc() {
    local vpcName="$1" vpc_info_file="$2"

    "${IBMCLOUD_CLI}" is vpc ${vpcName} --show-attached --output JSON > "${vpc_info_file}" || return 1
}

#####################################
##############Initialize#############
#####################################
ibmcloud_login
#create the bastion host based on the info (ibmcloud-provision-vpc ${SHARED_DIR}/customer_vpc_subnets.yaml), output ip info to ${SHARED_DIR}/bastion-info.yaml
cluster_name="${NAMESPACE}-${UNIQUE_HASH}"
bastion_info_yaml="${SHARED_DIR}/bastion-info.yaml"

bastion_name="${cluster_name}-bastion"
MACHINE_TYPE="bx2-8x32"
#The default coreos image value is gotten from
#imgProfile="fedora-coreos.*available.*amd64.*stable.*public"
#ibmcloud is images --visibility public --owner-type provider --resource-group-name Default | grep -i ${imgProfile}
IMAGE="ibm-fedora-coreos-41-stable-1"
workdir=${ARTIFACT_DIR}
bastion_ignition_file="${SHARED_DIR}/${cluster_name}-bastion.ign"

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, ignition-bastionhost step is required, abort." && exit 1
fi

echo "Reading variables from ibmcloud_vpc_name and ibmcloud_resource_group files..."
vpcName=$(<"${SHARED_DIR}/ibmcloud_vpc_name")
resource_group=$(<"${SHARED_DIR}/ibmcloud_resource_group")

echo "Using region: ${region}  resource_group: ${resource_group} vpc: ${vpcName}"
${IBMCLOUD_CLI} target -g ${resource_group}

vpc_info_file=$(mktemp)
check_vpc "${vpcName}" "${vpc_info_file}" || exit 1
vpc_arn=$(cat "${vpc_info_file}" | jq -r '.vpc.crn')
subnet=$(cat "${vpc_info_file}" | jq -c -r '[.subnets[] | select(.name|test("control-plane")) | .name][0]')

if [[ -z "${subnet}" ]]; then
  echo "ERROR" "Fail to get subnet of vpc ${vpcName}, abort" &&  exit 1
fi
echo "subnet: ${subnet}"
zone=$(${IBMCLOUD_CLI} is subnet ${subnet} --output JSON | jq -r '.zone.name')
echo "zone: ${zone}"
sg=$(${IBMCLOUD_CLI} is vpc-sg ${vpcName} --output JSON | jq -r .id)
echo "sg: ${sg}"

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
# always save bastion info to ensure deprovision works
cat > "${bastion_info_yaml}" << EOF
bastionHost: ${bastion_name}
vpcName: ${vpcName}
EOF
sleep 300

insFile="${workdir}/${bastion_name}.json"
run_command "${IBMCLOUD_CLI} is instance ${bastion_name} --output JSON > ${insFile}"
echo "INFO" "Created bastion instance ${bastion_name} status: $(jq -r '.status' ${insFile})"
bastion_private_ip="$(jq -r '.network_interfaces[0].primary_ip.address' ${insFile})"

nac=$(jq -r '.network_attachments[0].id' ${insFile})
nic=$(${IBMCLOUD_CLI} is instance-network-attachment ${bastion_name} ${nac} --output JSON | jq -r ".virtual_network_interface.id")
fip="${cluster_name}-fip"
${IBMCLOUD_CLI} is floating-ip-reserve ${fip} --nic-id $nic --output JSON > "${workdir}/${bastion_name}_ip.json"
bastion_public_ip=$(jq -r '.address' "${workdir}/${bastion_name}_ip.json")
echo "bastion_public_ip: $bastion_public_ip"
if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "ERROR" "Failed to find bastion's public and private IP!"
    exit 1
fi

# always save bastion info to ensure deprovision works
cat > "${bastion_info_yaml}" << EOF
publicIpAddress: ${bastion_public_ip}
privateIpAddress: ${bastion_private_ip}
bastionHost: ${bastion_name}
vpcName: ${vpcName}
EOF

#dump the info 
run_command "${IBMCLOUD_CLI} is instance-network-interface-floating-ips ${bastion_name} $nac"
run_command "${IBMCLOUD_CLI} is sg $sg"
#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
    mirror_registry_host="${bastion_name}.mirror-registry"
    mirror_registry_dns="${mirror_registry_host}.${BASE_DOMAIN}"

    if [[ "${MIRROR_REG_PRIVATE_DNS}" == "yes" ]]; then
        echo "INFO: Adding private DNS record for mirror registry"
        # get dns zone id
        cmd="ibmcloud dns zones -i ${IBMCLOUD_DNS_INSTANCE_NAME} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
        dns_zone_id=$(eval "${cmd}")
        [[ -z "${dns_zone_id}" ]] && echo "ERROR: Did not find dns zone id per the output of '${cmd}'" && exit 3

        # creating
        run_command "ibmcloud dns resource-record-create ${dns_zone_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME} --type A --name ${mirror_registry_host} --ipv4 ${bastion_private_ip}"

        # post-check
        dns_record_id=$(ibmcloud dns resource-records ${dns_zone_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME} -o json | jq -r --arg z "${mirror_registry_dns}" '.resource_records[] | select(.name==$z) | .id')
        [[ -z "${dns_record_id}" ]] && echo "ERROR: Did not find dns record id" && exit 3
        echo "ibmcloud dns resource-record-delete ${dns_zone_id} ${dns_record_id} -i ${IBMCLOUD_DNS_INSTANCE_NAME} -f || ture" >>"${SHARED_DIR}/ibmcloud_remove_resources_by_cli.sh"

        if [[ "${DNS_ASSOCIATE_VPC}" == "yes" ]]; then
            echo "INFO: associate dns zone with permitted vpc..."
            run_command "ibmcloud dns permitted-network-add ${dns_zone_id} --type vpc --vpc-crn ${vpc_arn} -i ${IBMCLOUD_DNS_INSTANCE_NAME}"
        fi
    fi

    if [[ "${MIRROR_REG_PUBLIC_DNS}" == "yes" ]]; then
        echo "INFO: Adding public DNS record for mirror registry"
        # get domain id
        ibmcloud_cis_instance_name=$(cat "${CLUSTER_PROFILE_DIR}/ibmcloud-cis")
        cmd="ibmcloud cis domains -i ${ibmcloud_cis_instance_name} -o json | jq -r --arg n ${BASE_DOMAIN} '.[] | select(.name==\$n) | .id'"
        domain_id=$(eval "${cmd}")
        [[ -z "${domain_id}" ]] && echo "ERROR: Did not find domain id per the output of '${cmd}'" && exit 3

        # pre-check
        cis_dns_record_id=$(ibmcloud cis dns-records ${domain_id} -i ${ibmcloud_cis_instance_name} -o json |  jq -r --arg z "${mirror_registry_dns}" '.[] | select(.name==$z) | .id')
        [[ -n "${cis_dns_record_id}" ]] && echo "ERROR: DNS record for ${mirror_registry_dns} already exists, exiting..." && exit 3

        # creating
        run_command "ibmcloud cis dns-record-create ${domain_id} -i ${ibmcloud_cis_instance_name} --type A --name ${mirror_registry_host} --content ${bastion_public_ip} --ttl 120"

        #post-check
        cis_dns_record_id=$(ibmcloud cis dns-records ${domain_id} -i ${ibmcloud_cis_instance_name} -o json |  jq -r --arg z "${mirror_registry_dns}" '.[] | select(.name==$z) | .id')
        [[ -z "${cis_dns_record_id}" ]] && echo "ERROR: Did not find cis dns record id" && exit 3
        echo "ibmcloud cis dns-record-delete ${domain_id} -i ${ibmcloud_cis_instance_name} ${cis_dns_record_id} || true" >>"${SHARED_DIR}/ibmcloud_remove_resources_by_cli.sh"

        # wait for a while before the 1st time of access
        # so that avoid the local dns cache long TTL when the new DNS is not delegated anywhere yet did not recieve the DNS record yet
        # once that, have to wait local dns cache's SOA TTL get expired 
        sleep 120s
    fi

    echo "Waiting for ${mirror_registry_dns} to be ready..." && sleep 120s
    # save mirror registry dns info
    echo "${mirror_registry_dns}:5000" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
#########Save Bastion Info###########
#####################################

echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

proxy_credential=$(cat /var/run/vault/proxy/proxy_creds)
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"
# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" > "${SHARED_DIR}/proxyip"

