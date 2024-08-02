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
PULL_SPEC=$PULL_SPEC&\
CNF_TEST_IMAGE_TAG=$CNF_TEST_IMAGE_TAG&\
DPDK_TEST_IMAGE_TAG=$DPDK_TEST_IMAGE_TAG&\
VERSION=$FULL_VERSION&\
KUBECONFIG_PATH=$KUBECONFIG_PATH&\
CNF_TEST_FEATURES_LIST=$CNF_TEST_FEATURES_LIST&\
CNF_TEST_ROLE=$CNF_TEST_ROLE&\
CNF_NODES_NUMBER=$CNF_NODES_NUMBER&\
CNF_PERF_TEST_PROFILE=$CNF_PERF_TEST_PROFILE&\
SCTPTEST_HAS_NON_CNF_WORKERS=$SCTPTEST_HAS_NON_CNF_WORKERS&\
RUN_PREPARE_STAGES=$RUN_PREPARE_STAGES&\
CNF_POLARION_REPORTING=$CNF_POLARION_REPORTING&\
DISCOVERY_MODE=$DISCOVERY_MODE&\
PROFILE_NAME=$PROFILE_NAME&\
OCP_EDGE_REPO=$OCP_EDGE_REPO&\
OCP_EDGE_BRANCH=$OCP_EDGE_BRANCH&\
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n')
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e job_params="$PARAMS" -e job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-cnf-tests/" -vvv
