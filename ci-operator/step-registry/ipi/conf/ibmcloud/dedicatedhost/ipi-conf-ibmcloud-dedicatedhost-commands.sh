#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

cat "${SHARED_DIR}/dedicated_host.yaml"

yq-go d -i ${CONFIG} "controlPlane.platform.ibmcloud.zones"

yq-go d -i ${CONFIG} "compute[0].platform.ibmcloud.zones"

yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/dedicated_host.yaml"

cat "${CONFIG}"


