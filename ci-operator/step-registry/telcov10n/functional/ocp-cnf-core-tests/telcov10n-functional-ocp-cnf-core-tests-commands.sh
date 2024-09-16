#!/bin/bash
set -e
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

SSH_KEY_PATH=/var/run/ssh-key/ssh-key
SSH_KEY=~/key
BASTION_IP_ADDR="$(cat /var/run/bastion-ip-addr/address)"
JENKINS_USER_NAME="$(cat /var/run/jenkins-credentials/jenkins-username)"
JENKINS_USER_TOKEN="$(cat /var/run/jenkins-credentials/jenkins-token)"

# Check connectivity
ping $BASTION_IP_ADDR -c 10 || true
echo "exit" | curl "telnet://$BASTION_IP_ADDR:22" && echo "SSH port is opened"|| echo "status = $?"

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

git clone https://github.com/openshift-kni/eco-ci-cd --depth=1 ${SHARED_DIR}/eco-ci-cd
cd ${SHARED_DIR}/eco-ci-cd/
ansible-galaxy collection install redhatci.ocp --ignore-certs


PARAMS=$(cat <<END_CAT
HOST=$LOCK_LBL_HOST&\
CLUSTER_NAME=$CLUSTER_NAME&\
RUN_CNF_GOTESTS=$RUN_CNF_GOTESTS&\
RUN_METRIC_TESTS=$RUN_METRIC_TESTS&\
RUN_PERFORMANCE_TESTS=$RUN_PERFORMANCE_TESTS&\
RUN_CNF_TESTS_DISCOVERY_MODE=$RUN_CNF_TESTS_DISCOVERY_MODE&\
UPLOAD_REPORTS=$UPLOAD_REPORTS&\
PREPARE_CLUSTER=$PREPARE_CLUSTER&\
DPDK_IMAGE_VERSION=$DPDK_TEST_IMAGE&\
CNF_IMAGE_VERSION=$CNF_TEST_IMAGE&\
CNF_TEST_FEATURES_LIST=$CNF_TEST_FEATURES_LIST&\
CNF_TEST_ROLE=$CNF_TEST_ROLE&\
VERSION=$VERSION&\
KUBECONFIG_PATH=$KUBECONFIG_PATH&\
CNF_GOTESTS_SRIOV_SMOKE=$CNF_GOTESTS_SRIOV_SMOKE&\
OCP_EDGE_REPO=$OCP_EDGE_REPO&\
OCP_EDGE_BRANCH=$OCP_EDGE_BRANCH&\
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n')
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e job_params="$PARAMS" -e job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-cnf-core-tests/" -vvv
