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
echo 'Deprovisioning HAProxy'

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" << 'EOF'
set -o nounset
CLUSTER_NAME="${1}"

devices=(eth1.br-ext eth2.br-int eth1.br-int)
for dev in "${devices[@]}"; do
  interface=${dev%%.*}
  bridge=${dev##*.}
  /usr/local/bin/ovs-docker del-port "$bridge" "$interface" "haproxy-$CLUSTER_NAME" || echo \
    "No $interface on $bridge for container haproxy-$CLUSTER_NAME"
done

echo Removing the HAProxy container
docker rm --force "haproxy-$CLUSTER_NAME"
rm -rf "/var/builds/$CLUSTER_NAME/haproxy"

EOF
