#!/bin/bash

set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

[ -z "${PULL_NUMBER:-}" ] && \
  timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
    test -f /var/builds/${NAMESPACE}/preserve && \
  exit 0

CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
echo 'Deprovisioning HAProxy'

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" << 'EOF'
set -euo pipefail

CLUSTER_NAME="${1}"

devices=(eth1.br-ext eth2.br-int)
for container_name in $(podman ps -a --format "{{.Names}}" | grep "haproxy-$CLUSTER_NAME"); do
  pid=$(podman inspect -f '{{ .State.Pid }}' "$container_name")
  for dev in "${devices[@]}"; do
    interface=${dev%%.*}
    bridge=${dev##*.}
    echo "Releasing IPv4 DHCP lease for $interface in $container_name"
    nsenter -m -u -n -i -p -t "$pid" \
          /sbin/dhclient -r \
          -pf "/etc/haproxy/dhclient.$interface.pid" \
          -lf "/etc/haproxy/dhclient.$interface.lease" \
          "$interface" || echo "No IPv4 lease for $interface"
    if [ "$bridge" = "br-int" ]; then
      echo "Releasing IPv6 DHCP lease for $interface in $container_name"
      nsenter -m -u -n -i -p -t "$pid" \
        /sbin/dhclient -6 -r \
        -pf "/etc/haproxy/dhclient.$interface.v6.pid" \
        -lf "/etc/haproxy/dhclient.$interface.v6.lease" \
        "$interface" || echo "No IPv6 lease for $interface"
    fi
    echo "Removing $interface from $bridge in $container_name"
    ovs-docker.sh del-port "$bridge" "$interface" "$container_name" || \
      echo "No $interface on $bridge for container $container_name"
  done

  echo "Removing HAProxy container $container_name"
  podman rm --force "${container_name}"
  rm -rf "/var/builds/$CLUSTER_NAME/haproxy*"
done

EOF
