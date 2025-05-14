#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set cluster variables
# CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")
# CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)

# Exports
# export CLUSTER_NAME CLUSTER_DOMAIN
export ARTIFACTS="${ARTIFACT_DIR}"
export PATH="${BIN_FOLDER}:${PATH}"
export KUBEVIRT_TESTING_CONFIGURATION_FILE=${KUBEVIRT_TESTING_CONFIGURATION_FILE:-'kubevirt-tier1-ocs.json'}

# Unset the following environment variables to avoid issues with oc command
unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT


set -x

# Get oc binary
# curl -sL "${OC_URL}" | tar -C "${BIN_FOLDER}" -xzvf - oc
curl -L "https://github.com/openshift-cnv/cnv-ci/tarball/release-${OCP_VERSION}" -o /tmp/cnv-ci.tgz
mkdir -p /tmp/cnv-ci
tar -xvzf /tmp/cnv-ci.tgz -C /tmp/cnv-ci --strip-components=1
cd /tmp/cnv-ci || exit 1

# Overwrite the default configuration file used for testing
# If KUBEVIRT_TESTING_CONFIGURATION is set and not empty, is has higher priority over KUBEVIRT_TESTING_CONFIGURATION_FILE
if [[ -n "${KUBEVIRT_TESTING_CONFIGURATION:-}" ]]; then
    export KUBEVIRT_TESTING_CONFIGURATION_FILE="${ARTIFACT_DIR}/kubevirt-testing-configuration.json"
    echo "${KUBEVIRT_TESTING_CONFIGURATION}" | tee "${KUBEVIRT_TESTING_CONFIGURATION_FILE}"
    echo "🔄 KUBEVIRT_TESTING_CONFIGURATION_FILE set to ${KUBEVIRT_TESTING_CONFIGURATION_FILE}"
fi

# Run the tests
make deploy_test || exit_code=$?

set +x

if [ "${exit_code:-0}" -ne 0 ]; then
    echo "deploy_test failed with exit code $exit_code"
    exit ${exit_code}
else
    echo "deploy_test succeeded"
fi
