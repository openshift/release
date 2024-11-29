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
set -o nounset
CLUSTER_NAME="${1}"

devices=(eth1.br-ext eth2.br-int eth1.br-int)
for container_name in $(podman ps -a --format "{{.Names}}" | grep "haproxy-$CLUSTER_NAME"); do
  for dev in "${devices[@]}"; do
    interface=${dev%%.*}
    bridge=${dev##*.}
    echo "Sending release dhcp lease for $interface in $container_name"
    nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' $container_name)" \
      /sbin/dhclient -r \
      -pf "/var/run/dhclient.$interface.pid" \
      -lf "/var/lib/dhcp/dhclient.$interface.lease" "$interface" || echo "No lease for $interface"
    echo "Removing $interface from $bridge in $container_name"
    ovs-docker.sh del-port "$bridge" "$interface" "$container_name" || echo \
      "No $interface on $bridge for container $container_name"
  done
  echo Removing the HAProxy container
  podman rm --force "${container_name}"
  rm -rf "/var/builds/$CLUSTER_NAME/haproxy*"
done

EOF
