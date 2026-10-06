#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/customer_managed_key_for_installer_sa.yaml"

if [ ! -f ${PATCH} ]; then
    echo "${PATCH} is not found!"
    exit 1
fi

# apply patch to install-config
yq-go m -x -i "${CONFIG}" "${PATCH}"
