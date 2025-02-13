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
LOCK_LABEL_HOST=$LOCK_LBL_HOST&\
VERSION=$VERSION&\
DU_USE_NEXUS_CACHE=$DU_USE_NEXUS_CACHE&\
DU_PULL_SPEC=$DU_PULL_SPEC&\
ZTP_VERSION=$ZTP_VERSION&\
ZTP_POLICIES_REPO_BRANCH=$ZTP_POLICIES_REPO_BRANCH&\
SPOKE_OPERATOR_IMAGES_SOURCE=$SPOKE_OPERATOR_IMAGES_SOURCE&\
UPLOAD_METRICS=$UPLOAD_METRICS&\
ZTP_SITECONFIG_REPO_BRANCH=$ZTP_SITECONFIG_REPO_BRANCH&\ 
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n') 
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e jjl_job_params="$PARAMS" -e jjl_job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-far-edge-vran-deployment/" -vvv
