#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

# Environment setup
cd cluster-post-config
./install-infra-workload.sh

# Remove the folder to resolve OCPQE-12185
rm -rf performance-dashboards
DITTYBOPPER_REPO=https://github.com/cloud-bulldozer/performance-dashboards.git
DITTYBOPPER_REPO_BRANCH=master
DITTYBOPPER_PARAMS=""
git clone --single-branch --branch $DITTYBOPPER_REPO_BRANCH --depth 1 $DITTYBOPPER_REPO
pushd performance-dashboards/dittybopper
./deploy.sh $DITTYBOPPER_PARAMS
popd
