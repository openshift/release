#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

timeout 10s ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "systemd-cat -t '${CLUSTER_NAME}' -p5 echo 'baremetal-lab-upi-conf-network: Configuring cluster networking'" || true

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
  ${SECONDARY_NET_MACHINE:+- ${SECONDARY_NET_MACHINE}}
EOF