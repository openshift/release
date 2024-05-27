#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

oc version
echo "OCP_VERSION : $OCP_VERSION"

if [ -n "${OCP_VERSION}" ]; then
    mkdir -p /tmp/openshift-client
    # Download and Extract the oc binary
    wget -O /tmp/openshift-client/openshift-client-linux-$OCP_VERSION.tar.gz https://mirror.openshift.com/pub/openshift-v4/clients/ocp/$OCP_VERSION/openshift-client-linux.tar.gz
    tar -C /tmp/openshift-client -xvf /tmp/openshift-client/openshift-client-linux-$OCP_VERSION.tar.gz
    export PATH=/tmp/openshift-client:$PATH
fi

oc version

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="janus-idp"
GITHUB_REPOSITORY_NAME="backstage-showcase"
NAME_SPACE="showcase-ci-nightly"
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/subhashkhileri/backstage-showcase.git"
cd backstage-showcase || exit
git checkout rhdh-configure-diff-ocp-version || exit

# bash ./.ibm/pipelines/openshift-ci-tests.sh
