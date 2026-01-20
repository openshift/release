#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
MICROSHIFT_PR=${MICROSHIFT_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
if [[ -f "${CLUSTER_PROFILE_DIR}/lab_cloud" ]]; then
  LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud)
elif [[ -f "${SHARED_DIR}/lab_cloud" ]]; then
  LAB_CLOUD=$(cat ${SHARED_DIR}/lab_cloud)
else
  echo "ERROR: lab_cloud not found in cluster profile or shared dir"
  exit 1
fi
export LAB_CLOUD
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN

# Get allocated nodes from QUADS
echo "Getting allocated nodes from QUADS..."
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
NODES=$(curl -sSk $OCPINV | jq -r ".nodes[0:${NUM_NODES}][].name")
if [[ -z "${NODES}" ]]; then
  echo "ERROR: No nodes returned from QUADS for lab cloud ${LAB_CLOUD}"
  exit 1
fi
echo "Nodes to deploy MicroShift on: $NODES"

# Copy SSH keys from bastion to provisioned nodes
echo "Copying SSH keys to provisioned nodes..."
for node in $NODES; do
  echo "Copying SSH key to ${node}..."
  ssh ${SSH_ARGS} root@${bastion} "
    ssh-keygen -R ${node} 2>/dev/null || true
    sshpass -p '${LOGIN}' ssh-copy-id -o StrictHostKeyChecking=no root@${node}
  "
done

# Create ansible inventory following the MicroShift ansible format
cat <<EOF >/tmp/microshift-inventory
[microshift]
EOF

# Add each node to inventory
for node in $NODES; do
  echo "${node}" >> /tmp/microshift-inventory
done

cat <<EOF >>/tmp/microshift-inventory

[microshift:vars]
ansible_user=root
ansible_ssh_private_key_file=/root/.ssh/id_rsa
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

[logging]
localhost ansible_connection=local

[logging:vars]
ansible_user=root
EOF

# Setup MicroShift
microshift_repo=/tmp/microshift-${LAB}-${LAB_CLOUD}-$(date +%s)
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   git clone https://github.com/openshift/microshift.git --depth=1 --branch=${MICROSHIFT_BRANCH:-main} ${microshift_repo}
   cd ${microshift_repo}
   # MICROSHIFT_PR or PULL_NUMBER can't be set at the same time
   if [[ -n '${MICROSHIFT_PR}' ]]; then
     git pull origin pull/${MICROSHIFT_PR}/head:${MICROSHIFT_PR} --rebase
     git switch ${MICROSHIFT_PR}
   elif [[ -n '${PULL_NUMBER}' ]] && [[ '${REPO_NAME}' == 'microshift' ]]; then
     git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
     git switch ${PULL_NUMBER}
   fi
   git branch
   
   # Install ansible if not present
   if ! command -v ansible &> /dev/null; then
     dnf install -y ansible-core
   fi

   # Install kubernetes module
   if ! command -v pip3 &> /dev/null; then
     dnf install -y python3-pip
   fi
   pip3 install kubernetes
"

# Discover storage layout on target nodes
echo "Discovering storage layout on target nodes..."
for node in $NODES; do
  echo "=== Storage info for ${node} ==="
  ssh ${SSH_ARGS} root@${bastion} "ssh root@${node} 'echo \"--- lsblk ---\" && lsblk && echo \"--- vgs ---\" && vgs 2>/dev/null || echo \"No volume groups found\" && echo \"--- pvs ---\" && pvs 2>/dev/null || echo \"No physical volumes found\"'"
done

# Copy inventory and pull secret to bastion
scp -q ${SSH_ARGS} /tmp/microshift-inventory root@${bastion}:${microshift_repo}/ansible/${ANSIBLE_INVENTORY}
set +x
scp -q ${SSH_ARGS} ${CLUSTER_PROFILE_DIR}/pull_secret root@${bastion}:${microshift_repo}/pull_secret.txt
set -x

# Run ansible playbook
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${microshift_repo}/ansible

   # Run the deployment playbook
   if [[ -f '${ANSIBLE_PLAYBOOK}' ]]; then
     ansible-playbook -i ${ANSIBLE_INVENTORY} ${ANSIBLE_PLAYBOOK} \
       -e "microshift_version=${MICROSHIFT_VERSION}" \
       -e "setup_microshift_host=${SETUP_MICROSHIFT_HOST}" \
       -e "install_microshift=${INSTALL_MICROSHIFT}" \
       -e "manage_repos=${MANAGE_REPOS}" \
       -e "prometheus_logging=${PROMETHEUS_LOGGING}" \
       -e "vg_name=${VG_NAME}" \
       -e "lvm_disk=${LVM_DISK}" \
       -v | tee /tmp/ansible-microshift-deploy-$(date +%s)
   else
     echo 'ERROR: Ansible playbook ${ANSIBLE_PLAYBOOK} not found'
     echo 'Available playbooks:'
     ls -la *.yml
     exit 1
   fi
   
   # Get kubeconfig from first node
   mkdir -p /root/$LAB/$LAB_CLOUD/microshift
   first_node=\$(head -n1 <(echo '$NODES'))
   scp root@\${first_node}:/var/lib/microshift/resources/kubeadmin/kubeconfig /root/$LAB/$LAB_CLOUD/microshift/kubeconfig || {
     echo 'WARNING: Could not retrieve kubeconfig from /var/lib/microshift/resources/kubeadmin/kubeconfig'
     echo 'Trying alternative location...'
     scp root@\${first_node}:~/.kube/config /root/$LAB/$LAB_CLOUD/microshift/kubeconfig || {
       echo 'ERROR: Could not retrieve kubeconfig from any known location'
       exit 1
     }
   }
"

# Copy kubeconfig to shared directory
scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/microshift/kubeconfig ${SHARED_DIR}/kubeconfig || {
  echo "ERROR: Failed to copy kubeconfig from bastion"
  exit 1
}

echo "MicroShift deployment completed successfully"
