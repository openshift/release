#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fix UID issue (from Telco QE Team)
~/fix_uid.sh

bastion=$(cat "/secret/address")
CRUCIBLE_URL=$(cat "/secret/crucible_url")

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
bastion_lab_interface: eno12399
bastion_controlplane_interface: ens6f0
controlplane_network: 192.168.216.1/21
controlplane_network_prefix: 21
bastion_vlaned_interface: ens1f1
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false
controlplane_lab_interface: eno1np0
controlplane_pub_network_cidr:
controlplane_pub_network_gateway:
jumbo_mtu: false
rwn_lab_interface: eno1np0
rwn_network_interface: ens1f0
install_rh_crucible: $CRUCIBLE
rh_crucible_url: "$CRUCIBLE_URL"
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

sshpass -p "$(cat /secret/login)" scp -q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /tmp/all-updated.yml root@${bastion}:~/jetlag/ansible/vars/all.yml
sshpass -p "$(cat /secret/login)" scp -q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /secret/pull_secret root@${bastion}:~/jetlag/pull_secret.txt

# Clean up previous attempts
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} ./clean-resources.sh

# Setup Bastion
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "
   set -e
   set -o pipefail
   cd jetlag
   if [[ -n '$JETLAG_PR' ]]; then
     git checkout main
     git branch -D dev || echo 'No dev branch exists'
     git fetch origin pull/$JETLAG_PR/head:dev
     git checkout dev
   elif [[ ${JETLAG_LATEST} == 'true' ]]; then
     git checkout main
     git pull
   else
     git pull origin $JETLAG_BRANCH
   fi
   git branch
   source bootstrap.sh
   ansible-playbook ansible/create-inventory.yml | tee /tmp/ansible-create-inventory-$(date +%s)
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/setup-bastion.yml | tee /tmp/ansible-setup-bastion-$(date +%s)"

# Attempt Deployment
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "
   set -e
   set -o pipefail
   cd jetlag
   git branch
   source bootstrap.sh
   ansible-playbook -i ansible/inventory/$LAB_CLOUD.local ansible/${TYPE}-deploy.yml -v | tee /tmp/ansible-${TYPE}-deploy-$(date +%s)"
