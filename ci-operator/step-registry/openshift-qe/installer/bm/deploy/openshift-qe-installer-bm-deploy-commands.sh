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
lab: scalelab
lab_cloud:
cluster_type: $TYPE
worker_node_count: $NUM_WORKER_NODES
sno_node_count:
public_vlan: false
ocp_release_image: $OCP_RELEASE_IMAGE
openshift_version: "$OCP_VERSION_SHORT"
networktype: OVNKubernetes
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
install_rh_crucible: "$CRUCIBLE"
rh_crucible_url: "$CRUCIBLE_URL"
EOF

envsubst < /tmp/all.yml > /tmp/all-updated.yml

sshpass -p "$(cat /secret/login)" scp -q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /tmp/all-updated.yml root@${bastion}:~/jetlag/ansible/vars/all.yml
sshpass -p "$(cat /secret/login)" scp -q -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null /secret/inventory root@${bastion}:~/jetlag/ansible/inventory/telco.inv

# Clean up previous attempts
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "./clean-resources.sh"

# Setup Bastion
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "cd jetlag; source bootstrap.sh; ansible-playbook -i ansible/inventory/telco.inv ansible/setup-bastion.yml"

# Attempt Deployment
sshpass -p "$(cat /secret/login)" ssh -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null root@${bastion} "cd jetlag; source bootstrap.sh; ansible-playbook -i ansible/inventory/telco.inv ansible/bm-deploy.yml -v"
