#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Destroying the dns and reloading bind9"
timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- "${NAMESPACE}" << 'EOF'
  set -o nounset
  NAMESPACE="${1}"
  sed -i "/; BEGIN ${NAMESPACE}/,/; END ${NAMESPACE}$/d" /opt/bind9_zones/{zone,internal_zone.rev}
  docker start bind9
  docker exec bind9 rndc reload
  docker exec bind9 rndc flush
EOF
