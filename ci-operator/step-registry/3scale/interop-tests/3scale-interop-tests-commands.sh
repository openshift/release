#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG="$HOME/.kube/config"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

echo "Login as kubeadmin to the test cluster at ${API_URL}..."
mkdir -p $HOME/.kube
touch $HOME/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

echo "Running 3scale interop tests"
make smoke

echo "Copying logs and xmls to ${ARTIFACT_DIR}"
cp /test-run-results/junit-smoke.xml ${ARTIFACT_DIR}/junit_3scale_smoke.xml
cp /test-run-results/report-smoke.html ${ARTIFACT_DIR}
