#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
###################################################################################################
# This is the last step and entryppoint when deploying infra/workload and move pods to infra node #
# It will invoke openshift-qe-workers-infra-workload and openshift-qe-move-pods-infra chain first #
# if you don't want to install performance-dashboards, please directly use chain                  #
# openshift-qe-workers-infra-workload and move-pods-infra                                         #
###################################################################################################

# Remove the folder to resolve OCPQE-12185
pushd /tmp
pwd
DITTYBOPPER_REPO_BRANCH=master
DITTYBOPPER_REPO=https://github.com/cloud-bulldozer/performance-dashboards.git
DITTYBOPPER_PARAMS=""
rm -rf performance-dashboards
git clone --single-branch --branch $DITTYBOPPER_REPO_BRANCH --depth 1 $DITTYBOPPER_REPO
pushd performance-dashboards/dittybopper
./deploy.sh $DITTYBOPPER_PARAMS
popd
