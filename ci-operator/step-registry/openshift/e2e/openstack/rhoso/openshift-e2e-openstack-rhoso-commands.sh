#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo setting up ansible
#export ANSIBLE_CALLBACKS_ENABLED="ansible.builtin.junit"
export JUNIT_OUTPUT_DIR="${ARTIFACT_DIR}/junit"
mkdir $ARTIFACT_DIR/ci-framework-data
mkdir $ARTIFACT_DIR/junit

echo setting up the env
export SERVER_NAME=$(grep proxy-url $UNDERLYING_KUBECONFIG | awk -F: '{$3 = substr ($3, 3); print $3}')
pip install kubernetes
# TBD: Once https://github.com/openstack-k8s-operators/ci-framework/pull/2572 is merged
# we can install the upstream repo
ansible-galaxy collection install git+https://github.com/shiftstack/ci-framework.git,fix-kubeconfig -f
cat <<EOF > ${ARTIFACT_DIR}/parent-playbook.yml
- name: "Run shiftstack"
  hosts: localhost
  gather_facts: false
  vars:
    ansible_user_dir: "${ARTIFACT_DIR}"
    cifmw_openshift_kubeconfig: "${UNDERLYING_KUBECONFIG}"
    cifmw_path: "${PATH}"
    cifmw_shiftstack_proxy: "http://${SERVER_NAME}:3128"
    cifmw_run_test_shiftstack_testconfig:
      - "${SHIFTSTACK_JOB_DEFINITION}.yaml"
  tasks:
    - block:
        - name: Run shiftstack role
          include_role:
            name: cifmw.general.shiftstack
      rescue:
        # To be improved to something more sophisticated
        - name: Create failure marker file
          copy:
            dest: "${ARTIFACT_DIR}/failed.md"
            content: "true"
            mode: '0644'
EOF

echo running the job
ansible-playbook ${ARTIFACT_DIR}/parent-playbook.yml

echo moving the junit so it can be parsed by Prow
cp \
${ARTIFACT_DIR}/ci-framework-data/tests/shiftstack/artifacts/0-${SHIFTSTACK_JOB_DEFINITION}/ansible_logs/*.xml \
${JUNIT_OUTPUT_DIR}
[ -f "${ARTIFACT_DIR}/failed.md" ] && exit 1
