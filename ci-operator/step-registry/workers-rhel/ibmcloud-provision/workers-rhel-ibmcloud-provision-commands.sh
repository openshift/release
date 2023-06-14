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

ibmcloud_login

export KUBECONFIG=${SHARED_DIR}/kubeconfig

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret

# Get existing vnet info
VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ ! -f "${VPC_CONFIG}" ]]; then
  echo "Fail to find of VPC info file ${VPC_CONFIG}, abort." && exit 1
fi
echo "Reading variables from ${VPC_CONFIG}..."
vpcName=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.vpcName')
resource_group=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.resourceGroupName')
infra_id=$(jq -r .infraID ${SHARED_DIR}/metadata.json)
echo "Using region: ${region}  resource_group: ${resource_group} vpc: ${vpcName}"

${IBMCLOUD_CLI} target -g ${resource_group}

workdir=`mktemp -d`

#when run more jobs at the same time, fail to create key with the same fingerprint, so create the key (ci-qe-key) in Default group for all test. 
${IBMCLOUD_CLI} is keys --all-resource-groups

#get the ssh key name from vault
rhelSSHKey="$(cat ${CLUSTER_PROFILE_DIR}/ibmcloud-sshkey-name)"

#use the same sgs created by installer, shared with the default rhcos nodes
rhel_worker_sgs="${infra_id}-sg-cluster-wide,${infra_id}-sg-openshift-net"
computeSubnetLength=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.computeSubnets' -l)

# Start to provision rhel instances from template in existing VPC and NSG
for count in $(seq 1 ${RHEL_WORKER_COUNT}); do
  echo "$(date -u --rfc-3339=seconds) - Provision ${infra_id}-rhel-${count} ..."
  # Get computeSubnet
  idx=$(((count-1) % $computeSubnetLength))
  
  subnet=$(yq-go r "${VPC_CONFIG}" "platform.ibmcloud.computeSubnets[${idx}]")
  zone=$(ibmcloud is subnet ${subnet} --output JSON | jq -r '.zone.name')
  volume="${infra_id}-vol-$count"
  vmName=${infra_id}-rhel-${count}
  echo "computeSubnet ${subnet} zone ${zone} volume $volume vmName $vmName"

  volumeJson=$(jq -n \
    --arg vn "$volume" \
    --argjson size ${RHEL_VM_DISK_SIZE} \
    '{"name": $vn, "volume": {"capacity": $size, "profile": {"name": "general-purpose"}}}')
  cmd="${IBMCLOUD_CLI} is instance-create $vmName ${vpcName} ${zone} ${RHEL_VM_SIZE} ${subnet} --image ${RHEL_IMAGE} --keys ${rhelSSHKey} --sgs ${rhel_worker_sgs} --boot-volume '${volumeJson}'"

  echo "Creating RHEL VM: ${cmd}"
  eval "${cmd}"
  sleep 60

  insFile="${workdir}/${vmName}.json"
  echo "create instance ${vmName}, recored in ${insFile} ..."
  ${IBMCLOUD_CLI} is instance ${vmName} --output JSON > ${insFile}
  cat ${insFile}
  echo "INFO" "Created instance ${vmName} status: $(jq -r '.status' ${insFile})"
  rhel_node_ip="$(jq -r '.network_interfaces[0].primary_ip.address' ${insFile})"
  echo "Ip address is ${rhel_node_ip}"
  
  if [ "x${rhel_node_ip}" == "x" ]; then
    echo "Unable to get ip of rhel instance ${infra_id}-rhel-${count}!"
    exit 1
  fi
   
  echo ${rhel_node_ip} >> /tmp/rhel_nodes_ip
done

cp /tmp/rhel_nodes_ip "${ARTIFACT_DIR}"

#Get bastion info
BASTION_SSH_USER=$(cat "${SHARED_DIR}/bastion_ssh_user")

BASTION_PUBLIC_IP=$(cat "${SHARED_DIR}/bastion_public_address")

#Generate ansible-hosts file
cat > "${SHARED_DIR}/ansible-hosts" << EOF
[all:vars]
openshift_kubeconfig_path=${KUBECONFIG}
openshift_pull_secret_path=${PULL_SECRET_PATH}
[new_workers:vars]
ansible_ssh_common_args="-o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -o IdentityFile=${SSH_PRIV_KEY_PATH} -o ConnectTimeout=30 -o ConnectionAttempts=100 -o StrictHostKeyChecking=no -W %h:%p -q ${BASTION_SSH_USER}@${BASTION_PUBLIC_IP}\""
ansible_user=${RHEL_USER}
ansible_become=True
[new_workers]
# hostnames must be listed by what `hostname -f` returns on the host
# this is the name the cluster will use
$(</tmp/rhel_nodes_ip)
[workers:children]
new_workers
EOF

cp "${SHARED_DIR}/ansible-hosts" "${ARTIFACT_DIR}"
