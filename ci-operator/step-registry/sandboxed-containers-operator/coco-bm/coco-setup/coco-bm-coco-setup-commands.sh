#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "#############################################################################..."
echo "========  Deploying CoCo on Intel TDX server ========"
echo "#############################################################################..."

SHARED_DIR="/root/cocobm-ci"

OCP_TYPE="sno"
PCCS_API_KEY=""

cat << EOF > $SHARED_DIR/setup_coco.yml
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

  - name: Deploy the CoCo with OpenShift sandboxed containers operator
    shell: cd ${SHARED_DIR}/sandboxed-containers-operator/scripts/install-helpers/baremetal-coco/ && PCCS_API_KEY=${PCCS_API_KEY} KUBECONFIG=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig sh install.sh -t tdx

  - name: Clone the Trustee operator repo
    git:
      repo: https://github.com/openshift/trustee-operator.git
      dest: ${SHARED_DIR}/trustee-operator
      version: main
      force: yes
      update: yes

  - name: Replace 0.4.2 with 0.4.1 for the trustee version in install.sh.[Workaround, will remove after 0.4.2 is supported]
    replace:
      path: ${SHARED_DIR}/trustee-operator/scripts/install-helpers/install.sh
      regexp: 'trustee-operator.v0.4.2'
      replace: 'trustee-operator.v0.4.1'
      backup: yes

  - name: Replace 0.4.2 with 0.4.1 for the trustee version in subs-ga.yaml.[Workaround, will remove after 0.4.2 is supported]
    replace:
      path: ${SHARED_DIR}/trustee-operator/scripts/install-helpers/subs-ga.yaml
      regexp: 'trustee-operator.v0.4.2'
      replace: 'trustee-operator.v0.4.1'
      backup: yes

  - name: Deploy the Trustee
    shell: cd ${SHARED_DIR}/trustee-operator/scripts/install-helpers && KUBECONFIG=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig TDX=true sh install.sh

EOF

cat << EOF > $SHARED_DIR/fetch-information.yml
---
- name: Fetch information about CoCo
  hosts: bastion
  gather_facts: false
  tasks:

  - name: Get runtimeclass
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig get runtimeclass
    ignore_errors: true

  - name: Get operators
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig get operators
    ignore_errors: true

  - name: Get pods under the OpenShift sandboxed containers operator
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig get pods -n openshift-sandboxed-containers-operator
    ignore_errors: true

  - name: Get pods under the Trustee operator
    shell: oc --kubeconfig=/root/${OCP_TYPE}/${OCP_TYPE}-0/kubeconfig get pods -n trustee-operator-system
    ignore_errors: true
EOF

cp $SHARED_DIR/setup_coco.yml $SHARED_DIR/jetlag/ansible/
cp $SHARED_DIR/fetch-information.yml $SHARED_DIR/jetlag/ansible/

status=0

echo "==========  Running Ansible to deploy CoCo on Intel TDX  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/setup_coco.yml  -vv || status=$?

echo "==========  Running Ansible to fetch information of CoCo  =========="
ANSIBLE_STDOUT_CALLBACK=debug ansible-playbook -i $SHARED_DIR/jetlag/ansible/inventory/byol-inventory-sno.sample $SHARED_DIR/jetlag/ansible/fetch-information.yml  -vv || status=$?


exit ${status}


