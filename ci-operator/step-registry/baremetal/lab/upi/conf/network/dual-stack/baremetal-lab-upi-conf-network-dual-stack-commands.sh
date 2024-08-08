#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to cobfigure networking: ${SHARED_DIR}/install-config.yaml"

cat > "${SHARED_DIR}/network_patch_install_config.yaml" <<EOF
networking:
  clusterNetwork:
  - cidr: fd02::/48
    hostPrefix: 64
  serviceNetwork:
  - fd03::/112
  machineNetwork:
  - cidr: ${INTERNAL_NET_V6_CIDR}
EOF
