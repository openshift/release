#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
cd /tmp || exit
WORKSPACE=$(pwd)

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

test=$(cat /tmp/secrets/osd/test)
echo "test : $test"

# GITHUB_ORG_NAME="redhat-developer"
# GITHUB_REPOSITORY_NAME="rhdh"
# git clone "https://github.com/subhashkhileri/rhdh.git"
# cd rhdh || exit
# git checkout osd-nightly-job || exit

# bash ./.ibm/pipelines/cluster/osd-gcp/create-osd.sh