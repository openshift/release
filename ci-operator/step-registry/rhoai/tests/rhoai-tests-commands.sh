#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

echo "This is the start SHARED_DIR: ${SHARED_DIR}"

#SECRETS_DIR="/tmp/secrets"
#export KUBECONFIG="{SHARED_DIR}/.kube/config"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p $SHARED_DIR/.kube
touch $SHARED_DIR/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
oc whoami --show-server

dir=$(ls "${SHARED_DIR}")
echo $dir

OCM_ENV=$API_HOST
SET_ENVIRONMENT="1"
OC_HOST=$(oc whoami --show-server)
#CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") || true
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token) || true
ROBOT_EXTRA_ARGS="-i $TEST_MARKER -e AutomationBug -e Resources-GPU -e Resources-2GPUS"
RUN_SCRIPT_ARGS="--skip-oclogin true --set-urls-variables true --test-artifact-dir ${ARTIFACT_DIR}/results"

export OCM_ENV
export SET_ENVIRONMENT
export OC_HOST
export CLUSTER_NAME
export OCM_TOKEN
export ROBOT_EXTRA_ARGS
export RUN_SCRIPT_ARGS
export CLUSTER_ID

mkdir "$ARTIFACT_DIR/results"

# running RHOAI testsuite
./ods_ci/build/run.sh
