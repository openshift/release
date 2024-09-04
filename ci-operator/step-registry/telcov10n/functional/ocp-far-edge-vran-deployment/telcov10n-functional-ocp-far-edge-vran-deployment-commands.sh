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

if [[ $DU_PULL_SPEC =~ ^latest-nightly-.* ]]; then
    # If DU_PULL_SPEC is latest-nightly-X.Y, automatically grab the latest nightly for the release.
    du_ocp_version="${DU_PULL_SPEC##*-}"

    DU_PULL_SPEC=$(curl -Ls "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${du_ocp_version}.0-0.nightly/latest" | jq -r '.pullSpec')
elif [[ $DU_PULL_SPEC =~ ^latest-.* ]]; then
    # If DU_PULL_SPEC is latest-X.Y, automatically grab the latest z stream/rc for the release.
    du_ocp_version="${DU_PULL_SPEC##*-}"
    du_ocp_version_plus_one=$(echo "$du_ocp_version" | awk -F '.' '{ print $1 "." $2 + 1}')
    
    DU_PULL_SPEC=$(curl -Ls "https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/4-stable/latest?in=%3E${du_ocp_version}.0-0+%3C${du_ocp_version_plus_one}.0-0" | jq -r '.pullSpec')
fi

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
MIRROR_SPOKE_OPERATOR_IMAGES=$MIRROR_SPOKE_OPERATOR_IMAGES&\
DEPLOY_DU=$DEPLOY_DU&\
RAN_METRICS_FORMAL_TEST=$RAN_METRICS_FORMAL_TEST
END_CAT
)

PARAMS=$(echo "$PARAMS" | tr -d '\n') 
ansible-playbook playbooks/launch-jenkins-job.yaml -i inventory \
 -e username=$JENKINS_USER_NAME \
 -e token=$JENKINS_USER_TOKEN \
 -e jjl_job_params="$PARAMS" -e jjl_job_url="https://${JENKINS_INSTANCE}-jenkins-csb-kniqe.apps.ocp-c1.prod.psi.redhat.com/job/ocp-far-edge-vran-deployment/" -vvv
