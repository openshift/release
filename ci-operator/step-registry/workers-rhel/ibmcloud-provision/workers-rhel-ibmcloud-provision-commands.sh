#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
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

ibmcloud_login

export KUBECONFIG=${SHARED_DIR}/kubeconfig

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret

infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
cluster_rg=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.ibmcloud.resourceGroupName}')

# Get existing vnet info
VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [[ ! -f "${VPC_CONFIG}" ]]; then
  echo "Fail to find of VPC info file ${VPC_CONFIG}, abort." && exit 1
fi
echo "Reading variables from ${VPC_CONFIG}..."
vpcName=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.vpcName')

echo "Using region: ${region}; resource_group: ${cluster_rg}; vpc: ${vpcName}"

${IBMCLOUD_CLI} target -g ${cluster_rg}

workdir=`mktemp -d`

#when run more jobs at the same time, fail to create key with the same fingerprint, so create the key (ci-qe-key) in Default group for all test. 
${IBMCLOUD_CLI} is keys --all-resource-groups

#get the ssh key name from vault
rhelSSHKey="$(cat ${CLUSTER_PROFILE_DIR}/ibmcloud-sshkey-name)"

#use the same sgs created by installer, shared with the default rhcos nodes
run_command "${IBMCLOUD_CLI} is sgs -q"
rhel_worker_sgs="${infra_id}-sg-cluster-wide,${infra_id}-sg-openshift-net"
echo "use the worker sgs: $rhel_worker_sgs"
computeSubnetLength=$(yq-go r "${VPC_CONFIG}" 'platform.ibmcloud.computeSubnets' -l)

# Start to provision rhel instances from template in existing VPC and NSG
for count in $(seq 1 ${RHEL_WORKER_COUNT}); do
  echo "$(date -u --rfc-3339=seconds) - Provision ${infra_id}-rhel-${count} ..."
  # Get computeSubnet
  idx=$(((count-1) % $computeSubnetLength))
  
  subnet=$(yq-go r "${VPC_CONFIG}" "platform.ibmcloud.computeSubnets[${idx}]")
  zone=$(${IBMCLOUD_CLI} is subnet ${subnet} --output JSON | jq -r '.zone.name')
  volume="${infra_id}-vol-$count"
  vmName=${infra_id}-rhel-${count}

  echo "computeSubnet: ${subnet}; zone: ${zone}; volume: $volume; vmName: $vmName"

  volumeJson=$(jq -n \
    --arg vn "$volume" \
    --argjson size ${RHEL_VM_DISK_SIZE} \
    '{"name": $vn, "volume": {"capacity": $size, "profile": {"name": "general-purpose"}}}')
  cmd="${IBMCLOUD_CLI} is instance-create $vmName ${vpcName} ${zone} ${RHEL_VM_SIZE} ${subnet} --image ${RHEL_IMAGE} --keys ${rhelSSHKey} --pnac-vni-sgs ${rhel_worker_sgs} --boot-volume '${volumeJson}'"

  echo "Creating RHEL VM..."
  run_command "${cmd}"
  sleep 120

  insFile="${workdir}/${vmName}.json"
  echo "create instance ${vmName}, recored in ${insFile} ..."
  ${IBMCLOUD_CLI} is instance ${vmName} --output JSON > ${insFile}
  cat ${insFile}
  echo "INFO" "Created instance ${vmName} status: $(jq -r '.status' ${insFile})"
  rhel_node_ip="$(jq -r '.network_interfaces[0].primary_ip.address' ${insFile})"
  echo "Ip address is ${rhel_node_ip}"
  
  if [[ -z "${rhel_node_ip}" ]]; then
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