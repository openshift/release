#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "#############################################################################..."
echo "========  Deploying SNO cluster on bare metal ========"
echo "#############################################################################..."

# Fix user IDs in a container
~/fix_uid.sh

SHARED_DIR="/tmp"
OCP_TYPE="sno"

SSH_PKEY_PATH=/usr/local/bm-bastion-$BM_LAB/secrets/BASTION_SSH_PRIVATE_KEY
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY
COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"

BASTION_IP=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_IP)
BASTION_USER=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_USER)
BASTION_LAB_INTERFACE=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_LAB_INTERFACE)
BASTION_CONTROLPLANE_INTERFACE=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_CONTROLPLANE_INTERFACE)
BASTION_BMC_ADDRESS=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_BMC_ADDRESS)
BASTION_BMC_USER=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_BMC_USER)
BASTION_PASSWORD=$(cat /usr/local/bm-bastion-$BM_LAB/secrets/BASTION_PASSWORD)
PULL_SECRET_PATH=/usr/local/bm-bastion-$BM_LAB/secrets/PULL_SECRET

SNO_CONTROLPLANE_LAB_INTERFACE=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_CONTROLPLANE_LAB_INTERFACE)
SNO_BMC_ADDRESS=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_BMC_ADDRESS)
SNO_MAC_ADDRESS=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_MAC_ADDRESS)
SNO_IP_ADDRESS=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_IP_ADDRESS)
SNO_VENDOR=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_VENDOR)
SNO_INSTALL_DISK=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_INSTALL_DISK)
SNO_BMC_USER=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_BMC_USER)
SNO_BMC_PASSWORD=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_BMC_PASSWORD)
SNO_HOST_NAME=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_HOST_NAME)

echo "==========  Customize Ansible files  =========="

cat << EOF > $SHARED_DIR/all.yml
lab: byol
lab_cloud:
cluster_type: "${OCP_TYPE}"
worker_node_count:
ocp_build: "${OCP_BUILD}"

# ocp_version is used in conjunction with ocp_build
# For "ga" builds, examples are "latest-4.17", "latest-4.16", "4.17.17" or "4.16.35"
# For "dev" builds, examples are "candidate-4.17", "candidate-4.16" or "latest"
# For "ci" builds, an example is "4.19.0-0.nightly-2025-02-25-035256"
ocp_version: "${OCP_VERSION}"
public_vlan: false
sno_use_lab_dhcp: true
enable_fips: false
enable_cnv_install: false
ssh_private_key_file: ~/.ssh/id_rsa
ssh_public_key_file: ~/.ssh/id_rsa.pub

################################################################################
# Bastion node vars
################################################################################

bastion_cluster_config_dir: /root/{{ cluster_type }}
smcipmitool_url:
bastion_lab_interface: "${BASTION_LAB_INTERFACE}"
bastion_controlplane_interface: "${BASTION_CONTROLPLANE_INTERFACE}"
setup_bastion_gogs: false
setup_bastion_registry: false
use_bastion_registry: false

################################################################################
# OCP node vars
################################################################################
# Network configuration for all mno/sno cluster nodes
controlplane_lab_interface: "${SNO_CONTROLPLANE_LAB_INTERFACE}"

################################################################################
# Extra vars
################################################################################
# Append override vars below
base_dns_name: kataci.com
labs:
  byol:
    dns:
    - ${SNO_IP_ADDRESS}
    ntp_server: clock.redhat.com
EOF

cat << EOF > $SHARED_DIR/byol-inventory-sno.sample
# Create inventory playbook will generate this for you much easier
[all:vars]
allocation_node_count=2
supermicro_nodes=False

[bastion]
${BASTION_IP} ansible_ssh_user=${BASTION_USER} bmc_address=${BASTION_BMC_ADDRESS} lab_ip=${BASTION_IP} ansible_ssh_common_args="$COMMON_SSH_ARGS" ansible_ssh_private_key_file="${SSH_PKEY}"

[bastion:vars]
bmc_user=${BASTION_BMC_USER}
bmc_password=${BASTION_PASSWORD}

[controlplane]

[controlplane:vars]

[worker]

[worker:vars]

[sno]
${SNO_HOST_NAME} bmc_address=${SNO_BMC_ADDRESS} mac_address=${SNO_MAC_ADDRESS} lab_mac=${SNO_MAC_ADDRESS} ip=${SNO_IP_ADDRESS} vendor=${SNO_VENDOR} install_disk=${SNO_INSTALL_DISK} boot_iso=${SNO_HOST_NAME}.iso

[sno:vars]
role=master
bmc_user=${SNO_BMC_USER}
bmc_password=${SNO_BMC_PASSWORD}
lab_interface=${SNO_CONTROLPLANE_LAB_INTERFACE}
network_interface=${SNO_CONTROLPLANE_LAB_INTERFACE}

[hv]

[hv:vars]

[hv_vm]
EOF

cat << EOF > $SHARED_DIR/clean_bastion_env.yml
---
- name: Clean the environment of bastion server
  hosts: bastion
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

  - name: Delete assisted installer previous deployments
    shell: curl http://${BASTION_IP}:8090/api/assisted-install/v2/clusters | jq '.[].id' -r | xargs -I % curl -X DELETE http://${BASTION_IP}:8090/api/assisted-install/v2/clusters/%
    ignore_errors: true

  - name: Gather facts about all pods
    containers.podman.podman_pod_info:
    register: pod_info

  - name: Setting facts for pod IDs
    set_fact:
      pod_id: "{{ pod_info.pods | json_query('[].Id') }}"

  - name: Remove all pods(assisted-service and http-store) 
    containers.podman.podman_pod:
      name: "{{ item }}"
      state: absent
    loop: "{{ pod_id }}"

  - name: Gather facts about all container images
    containers.podman.podman_image_info:
    register: image_info

  - name: Setting facts for image IDs
    set_fact:
      image_id: "{{ image_info.images | json_query('[].Id') }}"

  - name: Remove all images(assisted-service,assisted-installer-ui,assisted-image-service and httpd-24-centos7 etc) 
    containers.podman.podman_image:
      name: "{{ item }}"
      state: absent
    loop: "{{ image_id }}"

  - name: Delete assisted-service files
    file:
      path: /opt/assisted-service
      state: absent

  - name: Delete http files
    file:
      path: /opt/http_store
      state: absent

  - name: Delete ocp files
    file:
      path: /opt/ocp-version
      state: absent
EOF

cat << EOF > $SHARED_DIR/fetch-information.yml
---
- name: Fetch information about cluster
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Get cluster version
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get clusterversion
    ignore_errors: true

  - name: Get bmh objects
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get bmh -A
    ignore_errors: true

  - name: Get nodes
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get node
    ignore_errors: true

  - name: Get MCP
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get mcp
    ignore_errors: true

  - name: Get operators
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get co
    ignore_errors: true
EOF

cat << EOF > $SHARED_DIR/check-cluster.yml
---
- name: Check if cluster is ready
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Check if cluster is available
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get clusterversion -o=jsonpath='{.items[0].status.conditions[?(@.type=='\''Progressing'\'')].status}'
    register: ready_check

  - name: Check for errors in cluster deployment
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get clusterversion
    register: error_check

  - name: Fail if deployment failed
    fail:
      msg: Installation has failed
    when: "'False' not in ready_check.stdout"

EOF

# Check bastion connectivity

echo "==========  Check bastion connection  =========="
ping ${BASTION_IP} -c 5 || true
echo "exit" | ncat ${BASTION_IP} 22 && echo "SSH port is opened"|| echo "status = $?"

echo "==========  Clone the Jetlag repo and copy customized Ansible files  =========="
# Clean the env
rm -rf $SHARED_DIR/jetlag
git clone https://github.com/redhat-performance/jetlag.git $SHARED_DIR/jetlag

cp $SHARED_DIR/all.yml $SHARED_DIR/jetlag/ansible/vars/
cp $SHARED_DIR/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/inventory/
cp $PULL_SECRET_PATH $SHARED_DIR/jetlag/pull_secret.txt
cp $SHARED_DIR/clean_bastion_env.yml $SHARED_DIR/jetlag/ansible/
cp $SHARED_DIR/check-cluster.yml $SHARED_DIR/jetlag/ansible/
cp $SHARED_DIR/fetch-information.yml $SHARED_DIR/jetlag/ansible/

#Set status and run playbooks
status=0

echo "==========  Running Ansible to clean bastion environment  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/clean_bastion_env.yml  -vv || status=$?

echo "==========  Running Ansible to setup bastion  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/setup-bastion.yml  -vv || status=$?

echo "==========  Running Ansible to deploy SNO  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/sno-deploy.yml  -vv || status=$?

echo "==========  Running Ansible to fetch SNO cluster info  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/fetch-information.yml -vv || status=$?

echo "==========  Running Ansible to check SNO cluster status  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/check-cluster.yml -vv || status=$?

exit ${status}

