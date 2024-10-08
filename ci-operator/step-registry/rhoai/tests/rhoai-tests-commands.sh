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

OCM_ENV=$API_HOST
SET_ENVIRONMENT="1"
OC_HOST=$(oc whoami --show-server)
#CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id") || true
#CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name") || true
if [[ -e ${SHARED_DIR}/metadata.json ]]; then
  # for OCP
  CLUSTER_ID=$(jq '.clusterID' ${SHARED_DIR}/metadata.json)
  CLUSTER_NAME=$(jq '.clusterName' ${SHARED_DIR}/metadata.json)
elif [[ -e ${SHARED_DIR}/cluster_id ]]; then
  # for ManagedCluster, e.g. ROSA
  echo "Reading infra id from file infra_id"
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
else
  echo "Error: No cluster id found, exit now"
  exit 1
fi

OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)
#ROBOT_EXTRA_ARGS="-i $TEST_MARKER -e AutomationBug -e Resources-GPU -e Resources-2GPUS"
ROBOT_EXTRA_ARGS="-i ODS-127"
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
