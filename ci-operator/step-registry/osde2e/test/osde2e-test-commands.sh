#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${CONFIGS}" ]]
then
    echo "CONFIGS is undefined. Set it and try again."
    exit 1
fi

if [[ -z "${SECRET_LOCATIONS}" ]]
then
    echo "SECRET_LOCATIONS is undefined. Set it and try again."
    exit 1
fi

if [[ -f "${SHARED_DIR}/kubeconfig" ]];
then
   export TEST_KUBECONFIG="${SHARED_DIR}/kubeconfig"
fi

if [[ -f "${SHARED_DIR}/cluster-id" ]]; then
    export CLUSTER_ID="$(< "${SHARED_DIR}/cluster-id")"
fi

if [[ -z "${CLUSTER_ID:-}" ]]; then
    echo "CLUSTER_ID is not set. Aborting test execution."
    exit 1
fi

export REPORT_DIR="${ARTIFACT_DIR}"

/osde2e test --configs "${CONFIGS}" \
--secret-locations "${SECRET_LOCATIONS}"