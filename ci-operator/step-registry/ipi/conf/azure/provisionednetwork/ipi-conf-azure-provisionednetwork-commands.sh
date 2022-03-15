#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/customer_vnet_subnets.yaml"
if [ ! -f ${PATCH} ]; then
    echo "${PATCH} is not found!"
    exit 1
else
    /tmp/yq m -x -i "${CONFIG}" "${PATCH}"
fi

NETWORK_PATCH="${SHARED_DIR}/network_machinecidr.yaml"
if [ ! -f "${NETWORK_PATCH}" ]; then
    echo "${NETWORK_PATCH} is not found!"
    exit 1
else
    /tmp/yq m -x -i "${CONFIG}" "${NETWORK_PATCH}"
fi
