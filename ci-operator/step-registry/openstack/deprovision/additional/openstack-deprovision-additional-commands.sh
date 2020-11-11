#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${CLUSTER_PROFILE_DIR}/clouds.yaml"
CLUSTER_NAME=$(<"${SHARED_DIR}"/CLUSTER_NAME)
export CLUSTER_NAME

if [[ -d "${SHARED_DIR}/deprovision.d" ]]; then
    for deprovision in ${SHARED_DIR}/deprovision.d/*; do
        /usr/bin/env bash "$deprovision"
    done
else
    echo "Nothing to do."
fi
