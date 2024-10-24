#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

echo "This is the start SHARED_DIR: ${SHARED_DIR}"

export KUBECONFIG="{SHARED_DIR}/.kube/config"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
OC_HOST="$(oc whoami --show-server)"
mkdir "$ARTIFACT_DIR/results"
#ROBOT_EXTRA_ARGS="-i $TEST_MARKER -e AutomationBug -e Resources-GPU -e Resources-2GPUS"
ROBOT_EXTRA_ARGS="-i ODS-127"
RUN_SCRIPT_ARGS="--skip-oclogin false --set-urls-variables true --test-artifact-dir ${ARTIFACT_DIR}/results"

echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

echo "CA-Certificate: $REQUESTS_CA_BUNDLE"
CURRENT_CONTEXT_NAME=$(oc config current-context)
INFRA_CLUSTER_NAME=$(oc config view -o json | jq -r --arg CURRENT_CONTEXT_NAME "$CURRENT_CONTEXT_NAME" '.contexts[] | select(.name==$CURRENT_CONTEXT_NAME).context.cluster')
INFRA_CLUSTER_API=$(oc config view -o json | jq -r --arg INFRA_CLUSTER_NAME "$INFRA_CLUSTER_NAME" '.clusters[] | select(.name==$INFRA_CLUSTER_NAME).cluster.server')

oc config set-cluster ${INFRA_CLUSTER_NAME} \
  --kubeconfig=${KUBECONFIG} \
  --server=${INFRA_CLUSTER_API} \
  --certificate-authority=/etc/pki/ca-trust/source/anchors/Current-IT-Root-CAs.pem \
  --embed-certs=true

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

export OC_HOST
export CLUSTER_NAME
export CLUSTER_ID
export ROBOT_EXTRA_ARGS
export RUN_SCRIPT_ARGS

#sleep 3600
# running RHOAI testsuite
./run_robot_test.sh --skip-install ${RUN_SCRIPT_ARGS} --extra-robot-args "${ROBOT_EXTRA_ARGS}"
