#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure networking: ${SHARED_DIR}/network_patch_install_config.yaml"

if [[ "${ipv4_enabled:-false}" == "true" ]]; then
  PRIMARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  PRIMARY_NET_SERVICE="172.30.0.0/16"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
fi

if [[ "${ipv6_enabled:-false}" == "true" ]]; then
  PRIMARY_NET_CLUSTER="cidr: fd02::/48
    hostPrefix: 64"
  PRIMARY_NET_SERVICE="fd03::/112"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_V6_CIDR}"
fi

if [[ "${PRIMARY_NET}" == "ipv6" ]]; then
  SECONDARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  SECONDARY_NET_SERVICE="172.30.0.0/16"
  SECONDARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
fi

if [[ "${PRIMARY_NET}" == "ipv4" ]]; then
  PRIMARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  PRIMARY_NET_SERVICE="172.30.0.0/16"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
  SECONDARY_NET_CLUSTER="cidr: fd02::/48
    hostPrefix: 64"
  SECONDARY_NET_SERVICE="fd03::/112"
  SECONDARY_NET_MACHINE="cidr: ${INTERNAL_NET_V6_CIDR}"
fi

cat > "${SHARED_DIR}/network_patch_install_config.yaml" <<EOF
networking:
  clusterNetwork:
  ${PRIMARY_NET_CLUSTER:+- ${PRIMARY_NET_CLUSTER}}
  ${SECONDARY_NET_CLUSTER:+- ${SECONDARY_NET_CLUSTER}}
  serviceNetwork:
  ${PRIMARY_NET_SERVICE:+- ${PRIMARY_NET_SERVICE}}
  ${SECONDARY_NET_SERVICE:+- ${SECONDARY_NET_SERVICE}}
  machineNetwork:
  ${PRIMARY_NET_MACHINE:+- ${PRIMARY_NET_MACHINE}}
  ${SECONDARY_NET_MACHINE:+- ${SECONDARY_NET_MACHINE}}
EOF
