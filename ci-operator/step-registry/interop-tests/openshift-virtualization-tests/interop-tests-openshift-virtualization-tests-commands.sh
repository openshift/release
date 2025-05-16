#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

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

uv run pytest \
    --junitxml "${ARTIFACT_DIR}/xunit_results.xml" \
    --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
    -o cache_dir=/tmp \
    --tc=hco_subscription:kubevirt-hyperconverged
