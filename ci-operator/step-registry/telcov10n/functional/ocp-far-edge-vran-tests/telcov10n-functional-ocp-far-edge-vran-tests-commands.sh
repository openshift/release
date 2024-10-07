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


PARAMS=$(cat <<END_CAT
LOCK_LABEL_HOST=$LOCK_LBL_HOST&\
SPOKE_NAME=$SPOKE_NAME&\
TEST_TYPE=$TEST_TYPE&\
ECO_GOTESTS_IMAGE=$ECO_GOTESTS_IMAGE
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n') 
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e jjl_job_params="$PARAMS" -e jjl_job_url="https://${JENKINS_INSTANCE}-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-far-edge-vran-tests/" -vvv | tee ${SHARED_DIR}/reporting.txt
job_rc=$?

# Extract vran-tests jenkins job build number for vran-reporting job regardless
# of job success.
cat ${SHARED_DIR}/reporting.txt | grep -o '"displayName": "#[0-9]*' | awk -F '#' 'NR==1 {print $2}' > ${SHARED_DIR}/vran-tests-build-number.txt

exit $job_rc
