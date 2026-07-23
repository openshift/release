#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
HAPROXY="$(<"${SHARED_DIR}"/haproxy.cfg)"

echo "Generating the dhclient configuration"
DHCLIENT='
option rfc3442-classless-static-routes code 121 = array of unsigned integer 8;

send host-name = gethostname();
request subnet-mask, broadcast-address, time-offset, host-name,
        netbios-name-servers, netbios-scope, interface-mtu,
        ntp-servers;

# Assuming eth1 will be the interface with the default gateway route
interface "eth1" {
    also request routers, domain-name, domain-name-servers, domain-search,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers;
}

interface "eth2" {
    also request routers, domain-name, domain-name-servers, domain-search,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers;
}
'

echo "Pushing the configuration and starting the load balancer in the auxiliary host..."

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

timeout -s 9 12m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" "${DISCONNECTED}" "'${HAPROXY}'"  "'${DHCLIENT}'"  << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${1}"
DISCONNECTED="${2}"
HAPROXY="${3}"
DHCLIENT="${4}"
BUILD_DIR="/var/builds/${CLUSTER_NAME}"
HAPROXY_DIR="$BUILD_DIR/haproxy"

mkdir -p "$HAPROXY_DIR"
echo -e "${HAPROXY}" >> "$HAPROXY_DIR/haproxy.cfg"
echo -e "${DHCLIENT}" >> "$HAPROXY_DIR/dhclient.conf"

echo "Create and start HAProxy container..."
podman run --name "haproxy-$CLUSTER_NAME" -d --restart=always \
  -v "$HAPROXY_DIR:/etc/haproxy:Z" \
  -v "$HAPROXY_DIR/haproxy.cfg:/etc/haproxy.cfg:Z" \
  -v "$HAPROXY_DIR/dhclient.conf:/etc/dhcp/dhclient.conf:Z" \
  --network none \
  quay.io/openshifttest/haproxy:armbm

echo "Setting the network interfaces in the HAProxy container"

CONTAINER_PID=$(podman inspect -f '{{ .State.Pid }}' "haproxy-$CLUSTER_NAME")

# For the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interfaces.
# eth2 will only get local routes configuration
devices=( eth1.br-ext eth2.br-int )
api_ip_interface=eth1
if [ x"${DISCONNECTED}" == x"true" ]; then
  api_ip_interface=eth2
fi

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

echo "Acquiring network lock $LOCK_FD ($LOCK) (waiting up to 10 minutes)"
if ! flock -w 600 "$LOCK_FD"; then
    echo "Error: Failed to acquire network lock within 10 minutes."
    exit 1
fi
echo "Network lock acquired"

echo "Attaching all ports to the container..."
for dev in "${devices[@]}"; do
  interface=${dev%%.*}
  bridge=${dev##*.}
  # for the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interface
  # eth2 will only get local routes configuration
  ovs-docker.sh add-port "$bridge" "$interface" "haproxy-$CLUSTER_NAME"
done

echo "Launching global IPv4 DHCP client for BOTH interfaces..."
nsenter -m -u -n -i -p -t "$CONTAINER_PID" \
  /sbin/dhclient -nw -v \
  -pf "/etc/haproxy/dhclient.v4.pid" \
  -lf "/etc/haproxy/dhclient.v4.lease" eth1 eth2 201>&-

echo "Waiting for interfaces to obtain IP addresses inside the container namespace..."
for i in {1..60}; do
  if nsenter -m -u -n -i -p -t "$CONTAINER_PID" /sbin/ip -o -4 a list "${api_ip_interface}" | grep -q 'inet '; then
    if [ "${DISCONNECTED}" == "true" ] || nsenter -m -u -n -i -p -t "$CONTAINER_PID" /sbin/ip -o -4 a list eth2 | grep -q 'inet '; then
      echo "IP addresses successfully assigned."
      break
    fi
  fi

  if [ "$i" -eq 60 ]; then
    echo "Timed out waiting for DHCP IP assignment inside container. Exiting."
    exit 1
  fi
  sleep 0.5
done

# Handle IPv6 configuration only for eth2
if [[ " ${devices[*]} " == *" eth2.br-int "* ]]; then
  echo "Launching IPv6 DHCP client for eth2..."
  nsenter -m -u -n -i -p -t "$CONTAINER_PID" \
    /sbin/dhclient -6 -N -v \
    -cf /dev/null \
    -pf "/etc/haproxy/dhclient.eth2.v6.pid" \
    -lf "/etc/haproxy/dhclient.eth2.v6.lease" eth2 201>&-
  sleep 5
fi

cleanup
trap - EXIT INT TERM

echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "haproxy-$CLUSTER_NAME"

echo "Gather the IP Address for the new interface"

api_ip=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n  \
  /sbin/ip -o -4 a list ${api_ip_interface} | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
if [ "${#api_ip}" -eq 0 ]; then
  echo "No IPv4 Address has been set for the external API VIP, failing"
  exit 1
fi

api_ip_v6=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n \
  /sbin/ip -o -6 a list ${api_ip_interface} | grep global | sed 's/.*inet6 \(.*\)\/[0-9]* scope global.*/\1/')
if [ "${#api_ip_v6}" -eq 0 ]; then
  echo "No global IPv6 Address has been set for the external API VIP, failing"
  exit 1
fi

if [ x"${DISCONNECTED}" != x"true" ]; then
  api_int_ip=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n  \
  /sbin/ip -o -4 a list eth2 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
  if [ "${#api_int_ip}" -eq 0 ]; then
    echo "No IPv4 Address has been set for internal api-int, failing"
    exit 1
  fi

  api_int_ip_v6=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n \
    /sbin/ip -o -6 a list eth2 | grep global | sed 's/.*inet6 \(.*\)\/[0-9]* scope global.*/\1/')
    if [ "${#api_int_ip_v6}" -eq 0 ]; then
      echo "No global IPv6 Address has been set for internal IPv6 api-int, failing"
      exit 1
    fi
else
  api_int_ip="$api_ip"
  api_int_ip_v6="$api_ip_v6"
fi

# To get the eth1 IP to SSH through HAProxy
access_ip=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n  \
  /sbin/ip -o -4 a list eth1 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')

printf "ingress_vip: %s\napi_vip: %s\ningress_vip_v6: %s\napi_vip_v6: %s\napi_int: %s\napi_int_v6: %s" "$api_ip" "$api_ip" "$api_ip_v6" "$api_ip_v6" "$api_int_ip" "$api_int_ip_v6" > "$BUILD_DIR/external_vips.yaml"
printf "$access_ip" > "$BUILD_DIR/access_ip"
# TODO[disconnected/BM/IPI]
#if [ "$DISCONNECTED" == "true" ] && IPI; then
#  cp "$BUILD_DIR/vips.yaml" "$BUILD_DIR/external_vips.yaml"
#fi
EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips.yaml" \
"root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/access_ip" "${SHARED_DIR}/"
