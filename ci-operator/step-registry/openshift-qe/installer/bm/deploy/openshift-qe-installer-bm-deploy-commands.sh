#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat ${CLUSTER_PROFILE_DIR}/address)
CRUCIBLE_URL=$(cat ${CLUSTER_PROFILE_DIR}/crucible_url)
JETLAG_PR=${JETLAG_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}
KUBECONFIG_SRC=""
BASTION_CP_INTERFACE=$(cat ${CLUSTER_PROFILE_DIR}/bastion_cp_interface)
LAB=$(cat ${CLUSTER_PROFILE_DIR}/lab)
export LAB
LAB_CLOUD=$(cat ${CLUSTER_PROFILE_DIR}/lab_cloud || cat ${SHARED_DIR}/lab_cloud)
export LAB_CLOUD
LAB_INTERFACE=$(cat ${CLUSTER_PROFILE_DIR}/lab_interface)
if [[ "$NUM_WORKER_NODES" == "" ]]; then
  NUM_WORKER_NODES=$(cat ${CLUSTER_PROFILE_DIR}/num_worker_nodes)
  export NUM_WORKER_NODES
fi
QUADS_INSTANCE=$(cat ${CLUSTER_PROFILE_DIR}/quads_instance_${LAB})
export QUADS_INSTANCE
LOGIN=$(cat "${CLUSTER_PROFILE_DIR}/login")
export LOGIN


echo "Starting deployment on lab $LAB, cloud $LAB_CLOUD ..."

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
lab_cloud: $LAB_CLOUD
cluster_type: $TYPE
worker_node_count: $NUM_WORKER_NODES
public_vlan: $PUBLIC_VLAN
sno_use_lab_dhcp: false
enable_fips: $FIPS
ssh_private_key_file: ~/.ssh/id_rsa
ssh_public_key_file: ~/.ssh/id_rsa.pub
pull_secret: "{{ lookup('file', '../pull_secret.txt') }}"
bastion_cluster_config_dir: /root/{{ cluster_type }}
bastion_controlplane_interface: $BASTION_CP_INTERFACE
bastion_lab_interface: $LAB_INTERFACE
controlplane_lab_interface: $LAB_INTERFACE
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false
install_rh_crucible: $CRUCIBLE
rh_crucible_url: "$CRUCIBLE_URL"
payload_url: "${RELEASE_IMAGE_LATEST}"
EOF

if [[ $PUBLIC_VLAN == "false" ]]; then
  echo -e "controlplane_network: 192.168.216.1/21\ncontrolplane_network_prefix: 21" >> /tmp/all.yml
fi

if [[ ! -z "$NUM_HYBRID_WORKER_NODES" ]]; then
  HV_NIC_INTERFACE=$(cat "${CLUSTER_PROFILE_DIR}/hypervisor_nic_interface")
  export HV_NIC_INTERFACE

  cat <<EOF >>/tmp/all.yml
hybrid_worker_count: $NUM_HYBRID_WORKER_NODES
hv_ip_offset: 0
hv_vm_ip_offset: 36
hv_inventory: true
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_ssh_pass: $LOGIN
hypervisor_nic_interface_idx: $HV_NIC_INTERFACE
EOF
  cat <<EOF >>/tmp/hv.yml
install_tc: false
lab: $LAB
ssh_public_key_file: ~/.ssh/id_rsa.pub
use_bastion_registry: false
setup_hv_vm_dhcp: false
compact_cluster_dns_count: 0
standard_cluster_dns_count: 0
hv_vm_generate_manifests: false
sno_cluster_count: 0
hypervisor_nic_interface_idx: $HV_NIC_INTERFACE
EOF
fi

envsubst < /tmp/all.yml > /tmp/all-updated.yml

# Copy the ssh key to the bastion host
OCPINV=$QUADS_INSTANCE/instack/$LAB_CLOUD\_ocpinventory.json
bastion2=$(curl -sSk $OCPINV | jq -r ".nodes[0].name")
ssh ${SSH_ARGS} root@${bastion} "
   ssh-keygen -R ${bastion2}
   sshpass -p $LOGIN ssh-copy-id -o StrictHostKeyChecking=no root@${bastion2}
"

# Clean up previous attempts
cat > /tmp/clean-resources.sh << 'EOF'
echo 'Running clean-resources.sh'
dnf install -y podman
podman pod stop $(podman pod ps -q) || echo 'No podman pods to stop'
podman pod rm $(podman pod ps -q)   || echo 'No podman pods to delete'
podman stop $(podman ps -aq)        || echo 'No podman containers to stop'
podman rm $(podman ps -aq)          || echo 'No podman containers to delete'
rm -rf /opt/*
EOF

# Override JETLAG_BRANCH to main when JETLAG_LATEST is true
if [[ ${JETLAG_LATEST} == 'true' ]]; then
  JETLAG_BRANCH=main
fi

# Setup Bastion
jetlag_repo=/tmp/jetlag-${LAB}-${LAB_CLOUD}-$(date +%s)
ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   git clone https://github.com/redhat-performance/jetlag.git --depth=1 --branch=${JETLAG_BRANCH:-main} ${jetlag_repo}
   cd ${jetlag_repo}
   # JETLAG_PR or PULL_NUMBER can't be set at the same time
   if [[ -n '${JETLAG_PR}' ]]; then
     git pull origin pull/${JETLAG_PR}/head:${JETLAG_PR} --rebase
     git switch ${JETLAG_PR}
   elif [[ -n '${PULL_NUMBER}' ]] && [[ '${REPO_NAME}' == 'jetlag' ]]; then
     git pull origin pull/${PULL_NUMBER}/head:${PULL_NUMBER} --rebase
     git switch ${PULL_NUMBER}
   fi
   git branch
   source bootstrap.sh
"
# Save jetlag_repo for next Step(s) that may need this info
echo $jetlag_repo > ${SHARED_DIR}/jetlag_repo

cp ${CLUSTER_PROFILE_DIR}/pull_secret /tmp/pull-secret
oc registry login --to=/tmp/pull-secret

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${bastion}:${jetlag_repo}/ansible/vars/all.yml
scp -q ${SSH_ARGS} /tmp/pull-secret root@${bastion}:${jetlag_repo}/pull_secret.txt
scp -q ${SSH_ARGS} /tmp/clean-resources.sh root@${bastion}:/tmp/

if [[ ! -z "$NUM_HYBRID_WORKER_NODES" ]]; then
  scp -q ${SSH_ARGS} /tmp/hv.yml root@${bastion}:${jetlag_repo}/ansible/vars/hv.yml
fi


if [[ ${TYPE} == 'sno' ]]; then
  KUBECONFIG_SRC='/root/sno/{{ groups.sno[0] }}/kubeconfig'
else
  KUBECONFIG_SRC=/root/${TYPE}/kubeconfig
fi

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${jetlag_repo}
   source .ansible/bin/activate
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m script -a /tmp/clean-resources.sh
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/setup-bastion.yml | tee /tmp/ansible-setup-bastion-$(date +%s)
   if [[ ! -z \"$NUM_HYBRID_WORKER_NODES\" ]]; then
     export ANSIBLE_HOST_KEY_CHECKING=False
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/hv-setup.yml -v | tee /tmp/ansible-hv-setup-$(date +%s)
     ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/hv-vm-create.yml -v | tee /tmp/ansible-hv-vm-create-$(date +%s)
   fi
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/${TYPE}-deploy.yml -v | tee /tmp/ansible-${TYPE}-deploy-$(date +%s)
   mkdir -p /root/$LAB/$LAB_CLOUD/$TYPE
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m fetch -a 'src=${KUBECONFIG_SRC} dest=/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig flat=true'
   deactivate
   rm -rf .ansible
"

scp -q ${SSH_ARGS} root@${bastion}:/root/$LAB/$LAB_CLOUD/$TYPE/kubeconfig ${SHARED_DIR}/kubeconfig
