#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/customer_vpc_subnets.yaml"
if [ ! -f ${PATCH} ]; then
    echo "${PATCH} is not found!"
    exit 1
else
    yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
