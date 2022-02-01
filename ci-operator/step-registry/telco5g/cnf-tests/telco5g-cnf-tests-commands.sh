#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco5g cnf-tests commands ************"

cnf_dir=$(mktemp -d -t cnf-XXXXX)
cd "$cnf_dir" || exit 1

repo="https://github.com/openshift-kni/cnf-features-deploy.git"
branch="${PULL_BASE_REF}"
dir="cnf-features-deploy"

echo "cloning branch ${PULL_BASE_REF}"
git clone -b $branch $repo $dir

cd $dir
FEATURES_ENVIRONMENT="typical-baremetal" FEATURES="performance xt_u32 vrf sctp ovn" make functests-on-ci
