#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export TEST_COLLECT_BASE_DIR=${ARTIFACT_DIR}

OLM_CHANNEL=${OLM_CHANNEL:-latest}
export CAMEL_K_GLOBAL_OPERATOR_NS=${OPERATOR_NS:-'openshift-operators'}

echo "Login into the cluster"
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
oc login "https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443" \
  --username="kubeadmin" \
  --password="$(cat ${SHARED_DIR}/kubeadmin-password)" \
  --insecure-skip-tls-verify=true

sleep 300

if [[ -z "${VERSION}" ]]; then
  echo "'VERSION' ENV variable is not found - extract it from the cluster (from the '$OLM_CHANNEL' channel)"
  VERSION=$(oc get packagemanifests red-hat-camel-k -o jsonpath="{.status.channels[?(@.name=='${OLM_CHANNEL}')].currentCSVDesc.version}") || true
  # get rid of the build suffix for operator respins
  VERSION=${VERSION%+?*}
  #oc get packagemanifests red-hat-camel-k -o jsonpath="{.status.channels[?(@.name=='latest')].currentCSVDesc.version}" || true
fi
echo "VERSION=${VERSION}"

VERSION="1.10.5"

KAMEL_URL=https://mirror.openshift.com/pub/openshift-v4/clients/camel-k/${VERSION}/camel-k-client-${VERSION}-linux-64bit.tar.gz
echo "KAMEL_URL=${KAMEL_URL}"

RESULTS_DIR="${TEST_COLLECT_BASE_DIR:=/data/results}"
#GOCACHE=/go/.cache
GOPATH=/go

echo "Downloading KAMEL_CLI from ${KAMEL_URL}"
curl -L -s -o kamel_cli.tar.gz -O ${KAMEL_URL} && tar xzf kamel_cli.tar.gz || fail "Can't download KAMEL_CLI"
export KAMEL_BIN=${PWD}/kamel

echo "Running tests..."
go version
go test -timeout 20m -v ./e2e/common/support/startup_test.go -tags=integration $@ 2>&1 | tee ${RESULTS_DIR}/$common.log

# Rename xmls files to junit_*.xml
mv ${ARTIFACT_DIR}/common.xml ${ARTIFACT_DIR}/junit_common.xml
#mv ${ARTIFACT_DIR}/traits.xml ${ARTIFACT_DIR}/junit_traits.xml