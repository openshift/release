#!/bin/bash
set -e
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

SSH_KEY_PATH=/var/run/ssh-key/ssh-key
SSH_KEY=~/key
JENKINS_USER_NAME="$(cat /var/run/jenkins-credentials/jenkins-username)"
JENKINS_USER_TOKEN="$(cat /var/run/jenkins-credentials/auto-jenkins-token)"

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

ansible-galaxy collection install redhatci.ocp --ignore-certs


PARAMS=$(cat <<END_CAT
HOST=$LOCK_LBL_HOST&\
CLUSTER_NAME=$CLUSTER_NAME&\
OLM_CATALOG_SOURCE=$OLM_CATALOG_SOURCE&\
BYPASS_OLM_SYNC=$BYPASS_OLM_SYNC&\
OLM_USE_NEXUS=$OLM_USE_NEXUS&\
OPERATORS_LIST=$OPERATORS_LIST&\
OCP_EDGE_REPO=$OCP_EDGE_REPO&\
OCP_EDGE_BRANCH=$OCP_EDGE_BRANCH&\
ASSISTED_ADDITIONAL_SPOKE_IMAGE=$ASSISTED_ADDITIONAL_SPOKE_IMAGE&\
ANSIBLE_TAG=$ANSIBLE_TAG&\
OLM_ANSIBLE_EXTRA_ARGS=$OLM_ANSIBLE_EXTRA_ARGS&\
JENKINS_AGENT=$JENKINS_AGENT&\
JOB_TEST_RUN_ID=$JOB_TEST_RUN_ID&\
JOB_TEST_CASE_ID=$JOB_TEST_CASE_ID
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n')
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e job_params="$PARAMS" -e job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-olm-setup/" -vvv
