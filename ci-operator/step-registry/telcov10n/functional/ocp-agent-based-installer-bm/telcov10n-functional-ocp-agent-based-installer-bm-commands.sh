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

# NOTE(yprokule): PROFILE_OVERRIDE is a "text" field used to pass custom overrides

PARAMS=$(cat <<END_CAT
HOST=$LOCK_LBL_HOST&\
OCP_MAJOR_VERSION=$OCP_MAJOR_VERSION&\
OCP_MINOR_VERSION=$OCP_MINOR_VERSION&\
OPENSHIFT_RELEASE_IMAGE=$OPENSHIFT_RELEASE_IMAGE&\
DEPLOY=$DEPLOY&\
DISCONNECTED_INSTALL=$DISCONNECTED_INSTALL&\
OCP_EDGE_REPO=$OCP_EDGE_REPO&\
OCP_EDGE_BRANCH=$OCP_EDGE_BRANCH&\
PROFILE_NAME=$PROFILE_NAME&\
PROFILE_OVERRIDE=$PROFILE_OVERRIDE&\
REUSE_DISCONNECTED_REGISTRY=$REUSE_DISCONNECTED_REGISTRY&\
USE_NEXUS_CACHE=$USE_NEXUS_CACHE&\
CLUSTER_NAME=$CLUSTER_NAME&\
BASE_DOMAIN=$BASE_DOMAIN&\
PRECLEAN_LOCAL_REGISTRY=$PRECLEAN_LOCAL_REGISTRY&\
OVERRIDE_CLUSTERCONFIGS=$OVERRIDE_CLUSTERCONFIGS
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n')
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e job_params="$PARAMS" -e job_url="https://auto-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-agent-based-instlaller-bm/" -vvv
