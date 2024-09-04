#!/bin/bash

set -e
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

SSH_KEY_PATH=/var/run/ssh-key/ssh-key
SSH_KEY=~/key
JENKINS_USER_NAME="$(cat /var/run/jenkins-credentials/jenkins-username)"
JENKINS_USER_TOKEN="$(cat "/var/run/jenkins-credentials/${JENKINS_INSTANCE}-jenkins-token")"

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

ansible-galaxy collection install redhatci.ocp --ignore-certs

# Get vran-tests jenkins job relevant build number to read results from.
TESTS_BUILD_NUMBER=$(cat ${SHARED_DIR}/vran-tests-build-number.txt)

PARAMS=$(cat <<END_CAT
LOCK_LABEL_HOST=$LOCK_LBL_HOST&\
SPOKE_CLUSTER_NAME=$SPOKE_NAME&\
RESULTS_REPORT_PATH=https://${JENKINS_INSTANCE}-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-far-edge-vran-tests/$TESTS_BUILD_NUMBER/&\
RAN_HUB=$RAN_HUB&\
RAN_SPOKE=$RAN_SPOKE&\
UPLOAD_XML_SPLUNK=$UPLOAD_XML_SPLUNK&\
UPLOAD_XML_POLARION=$UPLOAD_XML_POLARION&\
UPLOAD_XML_REPORT_PORTAL=$UPLOAD_XML_REPORT_PORTAL&\
LAUNCH_NAME=$LAUNCH_NAME&\
LAUNCH_DESCRIPTION=$LAUNCH_DESCRIPTION&\
PYLARION_TITLE=$PYLARION_TITLE&\
CNF_POLARION_BRANCH=$CNF_POLARION_BRANCH&\
CNF_POLARION_REPO=$CNF_POLARION_REPO&\
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n') 
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e jjl_job_params="$PARAMS" -e jjl_job_url="https://${JENKINS_INSTANCE}-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-far-edge-vran-reporting/" -vv 
 
