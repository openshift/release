#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/customer_vnet_subnets.yaml"
if [ ! -f ${PATCH} ]; then
    echo "${PATCH} is not found!"
    exit 1
else
    yq-go m -x -i "${CONFIG}" "${PATCH}"
fi

NETWORK_PATCH="${SHARED_DIR}/network_machinecidr.yaml"
if [ ! -f "${NETWORK_PATCH}" ]; then
    echo "${NETWORK_PATCH} is not found!"
    exit 1
else
    yq-go m -x -i "${CONFIG}" "${NETWORK_PATCH}"
fi
