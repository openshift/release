#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
SHARED_DIR=/tmp/secret

echo Running on ${LEASED_RESOURCE}
echo "${USER:-default}:x:$(id -u):$(id -g):Default User:$HOME:/sbin/nologin" >> /etc/passwd
PROXY_USER=$(cat /var/run/cluster-secrets/openstack-rhoso/proxy-user)
cp /var/run/cluster-secrets/openstack-rhoso/proxy-private-key /tmp/id_rsa-proxy
chmod 0600 /tmp/id_rsa-proxy
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o PasswordAuthentication=no \
  -i /tmp/id_rsa-proxy \
  ${PROXY_USER}@${LEASED_RESOURCE}:~/kubeconfig $SHARED_DIR/rhoso_kubeconfig \
  || (echo "ABORTING! Selected RHOSO cloud is not ready to be used."; exit 130)
KUBECONFIG=$SHARED_DIR/rhoso_kubeconfig
oc get -n openstack openstackversions.core.openstack.org controlplane

echo RHOSO is healthy, preparing for deprovision the shiftstack cluster
JUNIT_OUTPUT_DIR="${ARTIFACT_DIR}/junit"
PROXY_URL=$(grep proxy-url: $KUBECONFIG | awk -F': ' '{print $2}' | head -1)
PROXY_CREDS=$(echo ${PROXY_URL} | awk -F'[@/]' '{print  $3}')
SHIFTSTACK_JOB_JUNIT_PATH=${ARTIFACT_DIR}/ci-framework-data/tests/shiftstack/artifacts/0-cluster-deprovision/ansible_logs

echo Setting the env
mkdir $ARTIFACT_DIR/ci-framework-data
mkdir $ARTIFACT_DIR/junit
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
    # REMOVE ONCE MERGED:
    cifmw_shiftstack_qa_gerrithub_change: "refs/changes/71/1208771/10"
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
  cp ${SHIFTSTACK_JOB_JUNIT_PATH}/*.xml ${JUNIT_OUTPUT_DIR}
fi

echo Cleaning the artifacts from the shiftstackclient pod
oc -n openstack rsh shiftstackclient-shiftstack bash -c 'rm -rf ~/artifacts/ansible_logs/'
[ -n "$failed" ] && { echo "return code $failed"; exit $failed; }
