#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-c2s-network.yaml.patch"

if [ ! -f "${SHARED_DIR}/machine_network" ]; then
  echo "File ${SHARED_DIR}/machine_network does not exist, abort."
  exit 1
fi

machine_network=$(head -n 1 "${SHARED_DIR}/machine_network")
cat > "${PATCH}" << EOF
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  machineNetwork:
  - cidr: ${machine_network}
  serviceNetwork:
  - 172.30.0.0/16
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
