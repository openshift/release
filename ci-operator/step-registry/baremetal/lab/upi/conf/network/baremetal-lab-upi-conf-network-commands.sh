#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure networking: ${SHARED_DIR}/network_patch_install_config.yaml"

if [ -n "${PRIMARY_NET}" ]; then
 if [[ "${ipv4_enabled:-true}" == "false" ]] || [[ "${ipv6_enabled:-false}" == "false" ]]; then
   echo "PRIMARY_NET=${PRIMARY_NET} should not be set for single-stack installations. Leave it empty as default.";
   exit 1
 fi
fi

if [[ "${ipv4_enabled:-false}" == "true" ]]; then
  PRIMARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  PRIMARY_NET_SERVICE="172.30.0.0/16"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
  PRIMARY_NET_MACHINE_TEST="cidr: 192.168.80.0/24"
fi

if [[ "${ipv6_enabled:-false}" == "true" ]]; then
  PRIMARY_NET_CLUSTER="cidr: fd02::/48
    hostPrefix: 64"
  PRIMARY_NET_SERVICE="fd03::/112"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_V6_CIDR}"
fi

case "${PRIMARY_NET}" in
ipv6)
  SECONDARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  SECONDARY_NET_SERVICE="172.30.0.0/16"
  SECONDARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
  ;;
ipv4)
  PRIMARY_NET_CLUSTER="cidr: 10.128.0.0/14
    hostPrefix: 23"
  PRIMARY_NET_SERVICE="172.30.0.0/16"
  PRIMARY_NET_MACHINE="cidr: ${INTERNAL_NET_CIDR}"
  PRIMARY_NET_MACHINE_TEST="cidr: 192.168.80.0/24"
  SECONDARY_NET_CLUSTER="cidr: fd02::/48
    hostPrefix: 64"
  SECONDARY_NET_SERVICE="fd03::/112"
  SECONDARY_NET_MACHINE="cidr: ${INTERNAL_NET_V6_CIDR}"
  ;;
esac

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
  ${PRIMARY_NET_MACHINE_TEST:+- ${PRIMARY_NET_MACHINE_TEST}}
  ${SECONDARY_NET_MACHINE:+- ${SECONDARY_NET_MACHINE}}
EOF