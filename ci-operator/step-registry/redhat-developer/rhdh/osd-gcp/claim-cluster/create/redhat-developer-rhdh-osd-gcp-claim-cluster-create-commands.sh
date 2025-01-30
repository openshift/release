#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
cd /tmp || exit
WORKSPACE=$(pwd)

curl -Lo ocm https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64

# GITHUB_ORG_NAME="redhat-developer"
# GITHUB_REPOSITORY_NAME="rhdh"
# git clone "https://github.com/subhashkhileri/rhdh.git"
# cd rhdh || exit
# git checkout osd-nightly-job || exit

# bash ./.ibm/pipelines/cluster/osd-gcp/create-osd.sh

git clone "https://github.com/subhashkhileri/rhdh.git"
cd rhdh || exit
git checkout osd-nightly-job || exit

job_id=$(echo -n $PROW_JOB_ID|cut -c-8)
export CLUSTER_NAME="osd-$job_id"

echo "CLUSTER_NAME : $CLUSTER_NAME"

bash ./.ibm/pipelines/cluster/osd-gcp/create-osd.sh

cp -v /tmp/rhdh/osdcluster/cluster-info.name "${SHARED_DIR}/"
cp -v /tmp/rhdh/osdcluster/cluster-info.id "${SHARED_DIR}/"
cp -v /tmp/rhdh/osdcluster/kubeconfig "${SHARED_DIR}/"

echo "cluster name in shared: "
echo "${SHARED_DIR}/cluster-info.name"
cat "${SHARED_DIR}/cluster-info.name"
