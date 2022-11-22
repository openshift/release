#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-osimage-vsphere.yaml.patch"

BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")

#patch clusterOSimage into install-config.yaml
cat > "${PATCH}" << EOF
platform:
  vsphere:
    clusterOSImage: http://${BASTION_IP}:80/rhcos-412.86.202209302317-0-vmware.x86_64.ova
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
