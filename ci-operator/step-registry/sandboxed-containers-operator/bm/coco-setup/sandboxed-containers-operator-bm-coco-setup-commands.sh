#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "#############################################################################..."
echo "========  Deploying CoCo on Intel TDX server ========"
echo "#############################################################################..."

if [ "$TEE_TYPE" != "tdx" ] && [ "$TEE_TYPE" != "snp" ]; then
    echo "Skip as TEE type not tdx or snp"
    exit 0
fi

SHARED_DIR="/tmp"

OCP_TYPE="sno"
SNO_HOST_NAME=$(cat /usr/local/bm-sno-$TEE_TYPE-$BM_LAB/secrets/SNO_HOST_NAME)
PCCS_API_KEY=$(cat /usr/local/bm-sno-tdx-$BM_LAB/secrets/PCCS_API_KEY)

SSH_PKEY_PATH=/usr/local/bm-bastion-$BM_LAB/secrets/BASTION_SSH_PRIVATE_KEY
SSH_PKEY=~/key
cp $SSH_PKEY_PATH $SSH_PKEY
chmod 600 $SSH_PKEY

cat << EOF > $SHARED_DIR/clone_install_helpers_repos.yml
---
- name: Setup CoCo with install helpers scripts
  hosts: bastion
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

  - name: Clone the OpenShift sandboxed containers repo
    git:
      repo: https://github.com/openshift/sandboxed-containers-operator.git
      dest: ${SHARED_DIR}/sandboxed-containers-operator
      version: devel
      force: yes
      update: yes

  - name: Clone the Trustee operator repo
    git:
      repo: https://github.com/openshift/trustee-operator.git
      dest: ${SHARED_DIR}/trustee-operator
      version: main
      force: yes
      update: yes
EOF

cat << EOF > $SHARED_DIR/setup_coco_tdx.yml
---
- name: Setup CoCo with install helpers scripts
  hosts: bastion
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

  - name: Deploy the CoCo with OpenShift sandboxed containers operator
    shell: cd ${SHARED_DIR}/sandboxed-containers-operator/scripts/install-helpers/baremetal-coco/ && PCCS_API_KEY=${PCCS_API_KEY} KUBECONFIG=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig sh install.sh -t tdx

  - name: Deploy the Trustee
    shell: cd ${SHARED_DIR}/trustee-operator/scripts/install-helpers && KUBECONFIG=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig TDX=true sh install.sh
EOF

cat << EOF > $SHARED_DIR/setup_coco_snp.yml
---
- name: Setup CoCo with install helpers scripts
  hosts: bastion
  tasks:

  - name: Wait 300 seconds, but only start checking after 10 seconds
    wait_for_connection:
      delay: 10
      timeout: 300

  - name: Deploy the CoCo with OpenShift sandboxed containers operator
    shell: cd ${SHARED_DIR}/sandboxed-containers-operator/scripts/install-helpers/baremetal-coco/ && KUBECONFIG=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig sh install.sh -t snp

  - name: Deploy the Trustee
    shell: cd ${SHARED_DIR}/trustee-operator/scripts/install-helpers && KUBECONFIG=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig sh install.sh
EOF


cat << EOF > $SHARED_DIR/fetch-information.yml
---
- name: Fetch information about CoCo
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Get runtimeclass
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get runtimeclass
    ignore_errors: true

  - name: Get operators
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get operators
    ignore_errors: true

  - name: Get pods under the OpenShift sandboxed containers operator
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get pods -n openshift-sandboxed-containers-operator
    ignore_errors: true

  - name: Get pods under the Trustee operator
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${SNO_HOST_NAME}/kubeconfig get pods -n trustee-operator-system
    ignore_errors: true
EOF

cp $SHARED_DIR/clone_install_helpers_repos.yml $SHARED_DIR/jetlag/ansible/

if [ "$TEE_TYPE" = "tdx" ]; then
    cp $SHARED_DIR/setup_coco_tdx.yml $SHARED_DIR/jetlag/ansible/setup_coco.yml
else
    cp $SHARED_DIR/setup_coco_snp.yml $SHARED_DIR/jetlag/ansible/setup_coco.yml
fi

cp $SHARED_DIR/fetch-information.yml $SHARED_DIR/jetlag/ansible/

status=0

echo "==========  Running Ansible to clone install helpers scripts  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/clone_install_helpers_repos.yml  -vv || status=$?

echo "==========  Running Ansible to deploy CoCo on Intel TDX  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/setup_coco.yml  -vv || status=$?

# Wait 60 seconds to check trustee pods running
sleep 60 

echo "==========  Running Ansible to fetch information of CoCo  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/fetch-information.yml  -vv || status=$?

exit ${status}
