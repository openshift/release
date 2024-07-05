#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

mkdir -p /tmp/openshift-client
# Download and Extract the oc binary
wget -O /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OC_CLIENT_VERSION/openshift-client-linux.tar.gz
tar -C /tmp/openshift-client -xvf /tmp/openshift-client/openshift-client-linux-$OC_CLIENT_VERSION.tar.gz
export PATH=/tmp/openshift-client:$PATH
oc version

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"
NAME_SPACE="showcase-ci-nightly"
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd backstage-showcase || exit

bash ./.ibm/pipelines/openshift-ci-tests.sh
