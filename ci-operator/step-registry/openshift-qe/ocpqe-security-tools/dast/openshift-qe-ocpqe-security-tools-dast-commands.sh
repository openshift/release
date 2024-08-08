#!/bin/bash

cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp || return
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

git clone $DAST_TOOL_URL --branch $DAST_TOOL_BRANCH --depth 1

git clone https://github.com/openshift-qe/ocpqe-security-tools.git --branch main --depth 1

ls

DAST_PATH=$(pwd)/rapidast

export DAST_PATH
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)"

pushd ocpqe-security-tools/dast || return
export NAMESPACE=default 
set +e

./deploy_ssml_api.sh
api_run_status=$?

echo "api_run_status $api_run_status"
ls

mkdir -p "${ARTIFACT_DIR}/rapidast_results"

cp -rpv "./results/"** "${ARTIFACT_DIR}/rapidast_results" 2>/dev/null

exit $api_run_status