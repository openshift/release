#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
echo "Destroying the dns and reloading bind9"
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "${CLUSTER_NAME}" << 'EOF'
  set -o nounset
  CLUSTER_NAME="${1}"
  sed -i "/; BEGIN ${CLUSTER_NAME}/,/; END ${CLUSTER_NAME}$/d" /opt/bind9_zones/{zone,internal_zone.rev}
  podman start bind9
  podman exec bind9 rndc reload
  podman exec bind9 rndc flush
EOF
