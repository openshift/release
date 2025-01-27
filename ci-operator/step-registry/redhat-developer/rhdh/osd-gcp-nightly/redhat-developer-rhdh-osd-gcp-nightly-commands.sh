#!/bin/bash
set -e
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=/tmp
cd /tmp || exit

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export CLUSTER_NAME="osd-$job_id"
echo "CLUSTER_NAME IN job : $CLUSTER_NAME"

exit 0

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
oc whoami 
export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN
K8S_CLUSTER_URL=$(oc whoami --show-server)
echo "K8S_CLUSTER_URL: $K8S_CLUSTER_URL"

echo "Note: This cluster will be automatically deleted 4 hours after being claimed."
echo "To debug issues or log in to the cluster manually, use the script: .ibm/pipelines/ocp-cluster-claim-login.sh"

oc create serviceaccount tester-sa-2 -n default
oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:default:tester-sa-2
K8S_CLUSTER_TOKEN=$(oc create token tester-sa-2 -n default)
oc logout

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

mkdir -p /tmp/openshift-client
# Download and Extract the oc binary
wget -O /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC_CLIENT_VERSION/openshift-client-linux.tar.gz
tar -C /tmp/openshift-client -xvf /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz
export PATH=/tmp/openshift-client:$PATH
oc version

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
NAME_SPACE="showcase-ci-nightly"
TAG_NAME="next"

# # Clone and checkout the specific PR
# git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
# cd rhdh || exit

git clone "https://github.com/subhashkhileri/rhdh.git"
cd rhdh || exit
git checkout osd-nightly-job || exit

bash ./.ibm/pipelines/openshift-ci-tests.sh
