#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

REGION="${LEASED_RESOURCE}"

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export SSH_PUB_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-publickey

infra_id=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)

VPC_CONFIG="${SHARED_DIR}/customer_vpc_subnets.yaml"
NETWORK=$(yq-go r "${VPC_CONFIG}" 'platform.gcp.network')
COMPUTE_SUBNET=$(yq-go r "${VPC_CONFIG}" 'platform.gcp.computeSubnet')
if [[ -z "${NETWORK}" || -z "${COMPUTE_SUBNET}" ]]; then
  echo "Could not find VPC network or compute subnet." && exit 1
fi
mapfile -t avail_zones < <(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[] | cut -d "/" -f9)

# Start to provision rhel instances in existing VPC
for count in $(seq 1 ${RHEL_WORKER_COUNT}); do
  echo "$(date -u --rfc-3339=seconds) - Provision ${infra_id}-rhel-${count} ..."
  gcloud compute instances create "${infra_id}-rhel-${count}" \
  --image=${RHEL_IMAGE} \
  --image-project="rhel-cloud" \
  --scopes=cloud-platform \
  --no-address \
  --boot-disk-size=${RHEL_VM_DISK_SIZE} \
  --machine-type="${RHEL_VM_SIZE}" \
  --network=${NETWORK} \
  --subnet=${COMPUTE_SUBNET} \
  --zone=${avail_zones[$(expr $count - 1)]} \
  --tags="${infra_id}-worker"
  
  rhel_node_ip=$(gcloud compute instances list --filter="name=${infra_id}-rhel-${count}" --format json | jq -r '.[].networkInterfaces[0].networkIP')
  echo "IP address is ${rhel_node_ip}"
  
  if [ "x${rhel_node_ip}" == "x" ]; then
    echo "Unable to get ip of rhel instance ${infra_id}-rhel-${count}!"
    exit 1
  fi

  echo ${rhel_node_ip} >> /tmp/rhel_nodes_ip
done

cp /tmp/rhel_nodes_ip "${ARTIFACT_DIR}"
#cp ${SHARED_DIR}/kubeconfig "${ARTIFACT_DIR}"

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
