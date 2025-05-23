#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
SHARED_DIR=/tmp/secret

KUBECONFIG=$SHARED_DIR/rhoso_kubeconfig
JUNIT_OUTPUT_DIR="${ARTIFACT_DIR}/junit"
PROXY_URL=$(grep proxy-url: $KUBECONFIG | awk -F': ' '{print $2}' | head -1)
PROXY_CREDS=$(echo ${PROXY_URL} | awk -F'[@/]' '{print  $3}')
SHIFTSTACK_JOB_JUNIT_PATH=${ARTIFACT_DIR}/ci-framework-data/tests/shiftstack/artifacts/0-cluster-deprovision/ansible_logs

echo Setting the env
mkdir -v $ARTIFACT_DIR/ci-framework-data
mkdir -v $ARTIFACT_DIR/junit
pip install kubernetes
ansible-galaxy collection install git+https://github.com/openstack-k8s-operators/ci-framework.git -f
cat <<EOF > ${ARTIFACT_DIR}/parent-playbook.yml
- name: "Run shiftstack"
  hosts: localhost
  gather_facts: false
  vars:
    ansible_user_dir: "${ARTIFACT_DIR}"
    cifmw_openshift_kubeconfig: "${KUBECONFIG}"
    cifmw_path: "${PATH}"
    cifmw_shiftstack_run_playbook: "cluster-deprovision.yaml"
    cifmw_run_test_shiftstack_testconfig:
      - "cluster-deprovision.yaml"
  tasks:
    - block:
        - name: Run shiftstack role
          import_role:
            name: cifmw.general.shiftstack
          environment:
            K8S_AUTH_PROXY: ${PROXY_URL}
            K8S_AUTH_PROXY_HEADERS_PROXY_BASIC_AUTH: ${PROXY_CREDS}
EOF

failed=0
echo Running the playbook to deprovision the existing cluster
ansible-playbook ${ARTIFACT_DIR}/parent-playbook.yml || failed=$?

if find "${SHIFTSTACK_JOB_JUNIT_PATH}" -maxdepth 1 -name "*.xml" | grep -q .; then
  echo "Moving the JUnit files so they can be parsed by Prow"
  cp -v ${SHIFTSTACK_JOB_JUNIT_PATH}/*.xml ${JUNIT_OUTPUT_DIR}
fi

echo Cleaning the artifacts from the shiftstackclient pod
oc -n openstack rsh shiftstackclient-shiftstack bash -c 'rm -rf ~/artifacts/ansible_logs/'
[ -n "$failed" ] && { echo "return code $failed"; exit $failed; }
