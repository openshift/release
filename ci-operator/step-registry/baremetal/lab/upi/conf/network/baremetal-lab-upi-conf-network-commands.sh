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

clusterNetwork=()
serviceNetwork=()
machineNetwork=()
EXTERNAL_PRIMARY_IPv4_NET_MACHINE=$(<"${CLUSTER_PROFILE_DIR}/external_ipv4_net")
EXTERNAL_PRIMARY_IPv6_NET_MACHINE=$(<"${CLUSTER_PROFILE_DIR}/external_ipv6_net")

case "${PRIMARY_NET}" in
ipv6)
  clusterNetwork+=("  - cidr: fd02::/48
    hostPrefix: 64")
  serviceNetwork+=("  - fd03::/112")
  machineNetwork+=("  - cidr: ${INTERNAL_NET_V6_CIDR}")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv6_NET_MACHINE}")
  fi
  # Add IPv4 Stack as Secondary
  clusterNetwork+=("  - cidr: 10.128.0.0/14
    hostPrefix: 23")
  serviceNetwork+=("  - 172.30.0.0/16")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv4_NET_MACHINE}")
  fi
  machineNetwork+=("  - cidr: ${INTERNAL_NET_CIDR}")
  ;;
ipv4)
  clusterNetwork+=("  - cidr: 10.128.0.0/14
    hostPrefix: 23")
  serviceNetwork+=("  - 172.30.0.0/16")
  machineNetwork+=("  - cidr: ${INTERNAL_NET_CIDR}")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv4_NET_MACHINE}")
  fi
  # Add IPv6 Stack as Secondary
  clusterNetwork+=("  - cidr: fd02::/48
    hostPrefix: 64")
  serviceNetwork+=("  - fd03::/112")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv6_NET_MACHINE}")
  fi
  machineNetwork+=("  - cidr: ${INTERNAL_NET_V6_CIDR}")
  ;;

"")
if [[ "${ipv4_enabled}" == "true" ]]; then
  clusterNetwork+=("  - cidr: 10.128.0.0/14
    hostPrefix: 23")
  serviceNetwork+=("  - 172.30.0.0/16")
  machineNetwork+=("  - cidr: ${INTERNAL_NET_CIDR}")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv4_NET_MACHINE}")
  fi
fi
if [[ "${ipv6_enabled}" == "true" ]]; then
  clusterNetwork+=("  - cidr: fd02::/48
    hostPrefix: 64")
  serviceNetwork+=("  - fd03::/112")
  machineNetwork+=("  - cidr: ${INTERNAL_NET_V6_CIDR}")
  if [ "${MULTIPLE_MACHINE_NETWORK:-false}" = "true" ]; then
    machineNetwork+=("  - cidr: ${EXTERNAL_PRIMARY_IPv6_NET_MACHINE}")
  fi
fi
;;
esac

(
IFS=$'\n'
cat > "${SHARED_DIR}/network_patch_install_config.yaml" <<EOF
networking:
  clusterNetwork:
${clusterNetwork[*]:+"${clusterNetwork[*]}"}
  serviceNetwork:
${serviceNetwork[*]:+"${serviceNetwork[*]}"}
  machineNetwork:
${machineNetwork[*]:+"${machineNetwork[*]}"}
EOF
)
echo "Patch file created successfully."