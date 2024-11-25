#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo setting up ansible
# Below var is commented as the junit of the parent-playbook run is just adding noise:
# export ANSIBLE_CALLBACKS_ENABLED="ansible.builtin.junit"
export JUNIT_OUTPUT_DIR="${ARTIFACT_DIR}/junit"
# Below var defines the path where the junit of shiftstack job is generated:
export SHIFTSTACK_JOB_JUNIT_PATH=${ARTIFACT_DIR}/ci-framework-data/tests/shiftstack/artifacts/0-${SHIFTSTACK_JOB_DEFINITION}/ansible_logs
mkdir $ARTIFACT_DIR/ci-framework-data
mkdir $ARTIFACT_DIR/junit

echo setting up the env
export PROXY_URL=$(grep proxy-url: $UNDERLYING_KUBECONFIG | awk -F': ' '{print $2}')
export PROXY_CREDS=$(cat $PROXY_CREDS_FILE)
pip install kubernetes
ansible-galaxy collection install git+https://github.com/openstack-k8s-operators/ci-framework.git -f
cat <<EOF > ${ARTIFACT_DIR}/parent-playbook.yml
- name: "Run shiftstack"
  hosts: localhost
  gather_facts: false
  vars:
    ansible_user_dir: "${ARTIFACT_DIR}"
    cifmw_openshift_kubeconfig: "${UNDERLYING_KUBECONFIG}"
    cifmw_path: "${PATH}"
    cifmw_run_test_shiftstack_testconfig:
      - "${SHIFTSTACK_JOB_DEFINITION}.yaml"
  tasks:
    - block:
        - name: Run shiftstack role
          import_role:
            name: cifmw.general.shiftstack
          environment:
            K8S_AUTH_PROXY: ${PROXY_URL}
            K8S_AUTH_PROXY_HEADERS_PROXY_BASIC_AUTH: ${PROXY_CREDS}
EOF

echo running the job
KUBECONFIG=${UNDERLYING_KUBECONFIG} oc annotate -n openstack openstackclients.client.openstack.org/openstackclient shiftstack_status=BUSY shiftstack_timestamp="$(date)"  --overwrite
ansible-playbook ${ARTIFACT_DIR}/parent-playbook.yml || failed=$?
KUBECONFIG=${UNDERLYING_KUBECONFIG} oc annotate -n openstack openstackclients.client.openstack.org/openstackclient shiftstack_status=FREE shiftstack_timestamp="$(date)"  --overwrite

if [ -f "${SHIFTSTACK_JOB_JUNIT_PATH}" ]; then
  echo moving the junit so it can be parsed by Prow
  cp ${SHIFTSTACK_JOB_JUNIT_PATH}/*.xml ${JUNIT_OUTPUT_DIR}
fi

[ -n "$failed" ] && { echo "Failing step with return code $failed"; exit $failed; }
