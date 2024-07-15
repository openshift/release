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

git clone $DAST_TOOL_URL --branch $DAST_TOOL_BRANCH --depth 1


git clone https://github.com/openshift-qe/ocpqe-security-tools.git --branch main --depth 1

ls

DAST_PATH=$(pwd)/rapidast

export DAST_PATH
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)"

pushd ocpqe-security-tools/dast

export NAMESPACE=default 
./deploy_ssml_api.sh

ls

mkdir -p "${ARTIFACT_DIR}/rapidast_results"

cp -rpv "./results/"** "${ARTIFACT_DIR}/rapidast_results" 2>/dev/null
