#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${OVN_IPV4_INTERNAL_SUBNET}" ]]; then
  echo "error: OVN_IPV4_INTERNAL_SUBNET is empty, exit now"
  exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
CONFIG_PATCH="${SHARED_DIR}/install-config-ovn-ipv4-subnet.yaml.patch"

echo "networking.ovnKubernetesConfig.ipv4.internalJoinSubnet: ${OVN_IPV4_INTERNAL_SUBNET}"

cat > "${CONFIG_PATCH}" << EOF
networking:
  ovnKubernetesConfig:
    ipv4:
      internalJoinSubnet: ${OVN_IPV4_INTERNAL_SUBNET}
EOF

yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH}"
