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
export PATH="${BIN_FOLDER}:${PATH}"

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
START_TIME=$(date "+%s")

# Get oc binary
# curl -sL "${OC_URL}" | tar -C "${BIN_FOLDER}" -xzvf - oc
curl -L "https://github.com/openshift-cnv/cnv-ci/tarball/release-${OCP_VERSION}" -o /tmp/cnv-ci.tgz
mkdir -p /tmp/cnv-ci
tar -xvzf /tmp/cnv-ci.tgz -C /tmp/cnv-ci --strip-components=1
cd /tmp/cnv-ci || exit 1

# Overwrite the default configuration file used for testing
export KUBEVIRT_TESTING_CONFIGURATION_FILE='kubevirt-tier1-ocs.json'
make deploy_test || exit_code=$?

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 720 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi

if [ "${exit_code:-0}" -ne 0 ]; then
    echo "deploy_test failed with exit code $exit_code"
    exit ${exit_code}
else
    echo "deploy_test succeeded"
fi
