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

run_olm_setup() {
  PARAMS=$(cat <<END_CAT
HOST=${LOCK_LBL_HOST}&\
OPERATORS_LIST=topology-aware-lifecycle-manager&\
OLM_ANSIBLE_EXTRA_ARGS=$1
END_CAT
  )

  PARAMS=$(echo "$PARAMS" | tr -d '\n')
  ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
  -e username=$JENKINS_USER_NAME \
  -e token=$JENKINS_USER_TOKEN \
  -e job_params="$PARAMS" -e job_url="https://${JENKINS_INSTANCE}-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-olm-setup/" -vvv
}

N_MINUS_ONE=$((TALM_MINOR_VERSION-1))
run_olm_setup "ocp_minor_version%3A%20%27${N_MINUS_ONE}%27%0Atalm_iib_override%3A%20%27registry.redhat.io%2Fredhat%2Fredhat-operator-index%3Av4.${N_MINUS_ONE}%27" &&
run_olm_setup "ocp_minor_version%3A%20%27${TALM_MINOR_VERSION}%27"
