#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set cluster variables
# CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")
# CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)
curl -L https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/stable/openshift-client-linux.tar.gz \
    | tar -C "${BIN_FOLDER}" -xzf - oc

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

poetry run pytest \
    --junitxml "${ARTIFACT_DIR}/xunit_results.xml" \
    --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
    -o cache_dir=/tmp \
    --tc=hco_subscription:kubevirt-hyperconverged \
    || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 600 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    ###
    ### TODO: Renabled once the tests takes more than 1 sec to finish
    ###
    # sleep 7200
    # exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi
