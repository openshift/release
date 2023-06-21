#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
XML_PATH="/tmp/release-tests/reports/xml-report/result.xml"

touch ${PWD}/config
export KUBECONFIG=${PWD}/config

echo "Login to the cluster as kubeadmin..."
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true

echo "Running olm.spec to install operator..."
CATALOG_SOURCE=redhat-operators CHANNEL=latest gauge run --log-level=debug --verbose --tags install specs/olm.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_olm_specs.xml

echo "Running gauge specs parallely..."
gauge run --log-level=debug --verbose --tags sanity -p specs/clustertasks/ specs/pipelines/ specs/triggers/ specs/hub/ specs/metrics/ specs/pac/ specs/operator/addon.spec specs/operator/post-upgrade.spec specs/operator/pre-upgrade.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_parallel_specs.xml

echo "Running auto-prune spec..."
gauge run --log-level=debug --verbose --tags sanity specs/operator/auto-prune.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_auto_prune.xml

echo "Running rbac spec..."
gauge run --log-level=debug --verbose --tags sanity specs/operator/rbac.spec
cp $XML_PATH ${ARTIFACT_DIR}/junit_rbac.xml
