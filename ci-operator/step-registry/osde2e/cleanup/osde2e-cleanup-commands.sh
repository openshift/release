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

if [[ ! -f "${SHARED_DIR}/cluster-id" ]];
then
    echo "File 'cluster-id' not found. Cluster may not have been provisioned."
    exit 1
fi

export REPORT_DIR="${ARTIFACT_DIR}"

/osde2e cleanup --configs "${CONFIGS}" \
--secret-locations "${SECRET_LOCATIONS}" \
--cluster-id "$(cat "${SHARED_DIR}/cluster-id")"
