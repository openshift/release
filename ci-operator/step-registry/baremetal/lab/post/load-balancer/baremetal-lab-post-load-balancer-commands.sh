#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BUILD_ID="${NAMESPACE}"
echo 'Deprovisioning HAProxy'

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${BUILD_ID}" << 'EOF'
set -o nounset
BUILD_ID="${1}"

devices=(eth1.br-ext eth2.br-int eth1.br-int)
for dev in "${devices[@]}"; do
  interface=${dev%%.*}
  bridge=${dev##*.}
  /usr/local/bin/ovs-docker del-port "$bridge" "$interface" "haproxy-$BUILD_ID" || echo \
    "No $interface on $bridge for container haproxy-$BUILD_ID"
done

echo Removing the HAProxy container
docker rm --force "haproxy-$BUILD_ID"
rm -rf "/var/builds/$BUILD_ID/haproxy"

EOF
