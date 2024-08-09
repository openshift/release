#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure ipv4 networking: ${SHARED_DIR}/ipv4_network_patch_install_config.yaml"

cat > "${SHARED_DIR}/ipv4_network_patch_install_config.yaml" <<EOF
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: ${INTERNAL_NET_CIDR}
EOF
