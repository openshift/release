#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export gauge_reports_dir=${ARTIFACT_DIR}
export overwrite_reports=false
export KUBECONFIG=$SHARED_DIR/kubeconfig

# Add timeout to ignore runner connection error
gauge config runner_connection_timeout 600000 && gauge config runner_request_timeout 300000

echo "Login to the cluster as kubeadmin"
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

echo "Running olm.spec to install operator"
CATALOG_SOURCE=redhat-operators CHANNEL=${OLM_CHANNEL} gauge run --log-level=debug --verbose --tags install specs/olm.spec || true

echo "Running gauge specs"
declare -a specs=("specs/clustertasks/clustertask-s2i.spec" "specs/clustertasks/clustertask.spec" "specs/pipelines/" "specs/triggers/" "specs/metrics/" "-p specs/operator/addon.spec specs/operator/auto-prune.spec")
for spec in "${specs[@]}"; do
  gauge run --log-level=debug --verbose --tags 'sanity & !tls' ${spec} || true
done
gauge run --log-level=debug --verbose --tags sanity specs/operator/rbac.spec || true

echo "Rename xml files to junit_test_*.xml"
readarray -t path <<< "$(find ${ARTIFACT_DIR}/xml-report/ -name '*.xml')"
for index in "${!path[@]}"; do
  mv "${path[index]}" ${ARTIFACT_DIR}/junit_test_result$[index+1].xml
done