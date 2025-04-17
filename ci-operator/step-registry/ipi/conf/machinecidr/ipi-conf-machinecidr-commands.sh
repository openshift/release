#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="/tmp/install-config-network-machine-cidr.patch"

if [[ -z "${NETWORK_MACHINECIDR}" ]]; then
    echo "ENV NETWORK_MACHINECIDR is empty, skip this step!"
    exit 0
fi

# save vnet information to ${SHARED_DIR} for later reference
cat > "${CONFIG_PATCH}" <<EOF
networking:
  machineNetwork:
  - cidr: "${NETWORK_MACHINECIDR}"
EOF

# apply patch to install-config.yaml
yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"

#for debug
cat "${CONFIG_PATCH}"
