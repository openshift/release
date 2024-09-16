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
ECO_GOTESTS_IMAGE=$ECO_GOTESTS_IMAGE&\
GINKGO_ARGS=$GINKGO_ARGS&\
JENKINS_AGENT=$JENKINS_AGENT&\
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n')
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e job_params="$PARAMS" -e job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-eco-gotests/" -vvv
