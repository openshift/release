#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

SSH_ARGS="-i /secret/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
bastion=$(cat "/secret/address")
CRUCIBLE_URL=$(cat "/secret/crucible_url")
JETLAG_PR=${JETLAG_PR:-}
REPO_NAME=${REPO_NAME:-}
PULL_NUMBER=${PULL_NUMBER:-}

cat <<EOF >>/tmp/all.yml
---
lab: $LAB
lab_cloud: $LAB_CLOUD
cluster_type: $TYPE
worker_node_count: $NUM_WORKER_NODES
sno_node_count: $NUM_SNO_NODES
public_vlan: false
ocp_version: $OCP_VERSION
ocp_build: $OCP_BUILD
networktype: OVNKubernetes
public_vlan: $PUBLIC_VLAN
enable_fips: $FIPS
ssh_private_key_file: ~/.ssh/id_rsa
ssh_public_key_file: ~/.ssh/id_rsa.pub
pull_secret: "{{ lookup('file', '../pull_secret.txt') }}"
bastion_cluster_config_dir: /root/{{ cluster_type }}
smcipmitool_url:
bastion_lab_interface: $BASTION_LAB_INTERFACE
bastion_controlplane_interface: $BASTION_CP_INTERFACE
controlplane_network: 192.168.216.1/21
controlplane_network_prefix: 21
bastion_vlaned_interface: $BASTION_VLANED_INTERFACE
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false
controlplane_lab_interface: $CONTROLPLANE_LAB_INTERFACE
controlplane_pub_network_cidr:
controlplane_pub_network_gateway:
jumbo_mtu: $ENABLE_JUMBO_MTU
install_rh_crucible: $CRUCIBLE
rh_crucible_url: "$CRUCIBLE_URL"
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

# Clean up previous attempts
cat > /tmp/clean-resources.sh << 'EOF'
podman pod stop $(podman pod ps -q) || echo 'No podman pods to stop'
podman pod rm $(podman pod ps -q)   || echo 'No podman pods to delete'
podman stop $(podman ps -aq)        || echo 'No podman containers to stop'
podman rm $(podman ps -aq)          || echo 'No podman containers to delete'
rm -rf /opt/*
EOF

jetlag_repo=/tmp/jetlag-${LAB}-${LAB_CLOUD}-$(date +%s)

# Setup Bastion
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

scp -q ${SSH_ARGS} /tmp/all-updated.yml root@${bastion}:${jetlag_repo}/ansible/vars/all.yml
scp -q ${SSH_ARGS} /secret/pull_secret root@${bastion}:${jetlag_repo}/pull_secret.txt

ssh ${SSH_ARGS} root@${bastion} "
   set -e
   set -o pipefail
   cd ${jetlag_repo}
   source .ansible/bin/activate
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible -i ansible/inventory/$LAB_CLOUD.local bastion -m script -a /root/clean-resources.sh
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/setup-bastion.yml | tee /tmp/ansible-setup-bastion-$(date +%s)
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/${TYPE}-deploy.yml -v | tee /tmp/ansible-${TYPE}-deploy-$(date +%s)
   deactivate
   rm -rf .ansible
"
