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

timeout -s 9 21m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" << 'EOF'
set -euo pipefail

CLUSTER_NAME="${1}"

LOCK="/tmp/dhclient_lease.lock"
LOCK_FD=201
touch "$LOCK"
exec 201>"$LOCK"

cleanup() {
  echo "Releasing network lock"
  flock -u "$LOCK_FD" 2>/dev/null || true
  exec 201>&- || true
}

trap cleanup EXIT INT TERM

echo "Acquiring network lock $LOCK_FD ($LOCK) (waiting up to 20 minutes)"
if ! flock -w 1200 "$LOCK_FD"; then
    echo "Error: Failed to acquire network lock within 20 minutes."
    exit 1
fi
echo "Network lock acquired"

devices=(eth1.br-ext eth2.br-int)
for container_name in $(podman ps -a --format "{{.Names}}" | grep "haproxy-$CLUSTER_NAME"); do
  pid=$(podman inspect -f '{{ .State.Pid }}' "$container_name")

  echo "Evaluating IPv4 DHCP lease status for $container_name..."
  # Only attempt release if a lease file exists and contains active records
  if [ -s "/var/builds/$CLUSTER_NAME/haproxy/dhclient.v4.lease" ] && \
     grep -q "lease {" "/var/builds/$CLUSTER_NAME/haproxy/dhclient.v4.lease"; then
    echo "Releasing global IPv4 DHCP leases for eth1 and eth2..."
    nsenter -m -u -n -i -p -t "$pid" \
          /sbin/dhclient -r \
          -pf "/etc/haproxy/dhclient.v4.pid" \
          -lf "/etc/haproxy/dhclient.v4.lease" \
          eth1 eth2 201>&-
  else
    echo "No active IPv4 lease record found to release."
  fi

  if [[ " ${devices[*]} " == *" eth2.br-int "* ]]; then
    echo "Evaluating IPv6 DHCP lease status for eth2 in $container_name..."
    if [ -s "/var/builds/$CLUSTER_NAME/haproxy/dhclient.eth2.v6.lease" ] && \
       grep -q "lease6 {" "/var/builds/$CLUSTER_NAME/haproxy/dhclient.eth2.v6.lease"; then
      echo "Releasing isolated IPv6 DHCP lease for eth2..."
      nsenter -m -u -n -i -p -t "$pid" \
        /sbin/dhclient -6 -r \
        -pf "/etc/haproxy/dhclient.eth2.v6.pid" \
        -lf "/etc/haproxy/dhclient.eth2.v6.lease" \
        eth2 201>&-
    else
      echo "No active IPv6 lease record found to release."
    fi
  fi

  for dev in "${devices[@]}"; do
    interface=${dev%%.*}
    bridge=${dev##*.}
    echo "Removing $interface from $bridge in $container_name"
    ovs-docker.sh del-port "$bridge" "$interface" "$container_name" || \
      echo "No $interface on $bridge for container $container_name"
  done

  echo "Removing HAProxy container $container_name"
  podman rm --force "${container_name}"
  rm -rf "/var/builds/$CLUSTER_NAME/haproxy*"
done

cleanup
trap - EXIT INT TERM
EOF
