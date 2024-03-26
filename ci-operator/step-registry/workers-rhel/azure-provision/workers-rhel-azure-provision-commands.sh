#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

AZURE_REGION="${LEASED_RESOURCE}"
export AZURE_REGION

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export SSH_PUB_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-publickey

infra_id=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
cluster_rg=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')

# Get bastion RG info
vnet_RG=$(cat ${SHARED_DIR}/resourcegroup)
echo "vnet resource group: ${vnet_RG}; cluster resource group: ${cluster_rg}"

# Get existing vnet info
if [ -f "${SHARED_DIR}/customer_vnet_subnets.yaml" ]; then
  VNET_FILE="${SHARED_DIR}/customer_vnet_subnets.yaml"
  vnet_name=$(yq-go r ${VNET_FILE} 'platform.azure.virtualNetwork')
  computeSubnet=$(yq-go r ${VNET_FILE} 'platform.azure.computeSubnet')
fi

# Get computeSubnet ID
computeSubnetID=$(az network vnet subnet show --resource-group ${vnet_RG} --vnet-name ${vnet_name} --name ${computeSubnet} --query id -o tsv)

# check if the current region support AZ by checking if $az_num != 0
IFS=$'\t' read -r -a zone_list <<< "$(az vm list-skus -l ${AZURE_REGION} --zone --size ${RHEL_VM_SIZE} --query '[].locationInfo[0].zones' -o tsv)"
az_num=${#zone_list[@]}

# Start to provision rhel instances from template in existing VNET and NSG
for count in $(seq 1 ${RHEL_WORKER_COUNT}); do
  echo "$(date -u --rfc-3339=seconds) - Provision ${infra_id}-rhel-${count} ..."

  # az command to create RHEL VM and append --zone when the region has AZ
  # add --assign-identity in the vm creation command to add cluster identity to the RHEL vm
  cmd="az vm create --resource-group '${cluster_rg}' --name '${infra_id}-rhel-${count}' --image '${RHEL_IMAGE}' --ssh-key-values '${SSH_PUB_KEY_PATH}' --admin-user '${RHEL_USER}' --public-ip-address '' --size '${RHEL_VM_SIZE}' --os-disk-size-gb '${RHEL_VM_DISK_SIZE}' --nsg '' --subnet '${computeSubnetID}' --assign-identity '${infra_id}-identity'"

  if [ "${az_num}" != "0" ]; then
    cmd="${cmd} --zone $((${count} % ${az_num} + 1))"
  fi

  echo "Creating RHEL VM: ${cmd}"
  eval "${cmd}" | tee /tmp/tmp.json 
 
  rhel_node_ip=$(cat /tmp/tmp.json | jq -r .privateIpAddress)
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
