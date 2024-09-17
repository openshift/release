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

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
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
podman run --name "haproxy-$CLUSTER_NAME" -d --restart=on-failure \
  -v "$HAPROXY_DIR/haproxy.cfg:/etc/haproxy.cfg:Z" \
  -v "$HAPROXY_DIR/dhclient.conf:/etc/dhcp/dhclient.conf:Z" \
  --network none \
  quay.io/openshifttest/haproxy:armbm

echo "Setting the network interfaces in the HAProxy container"

# For the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interfaces.
# eth2 will only get local routes configuration

devices=( eth1.br-ext eth2.br-int )
api_ip_interface=eth1

if [ x"${DISCONNECTED}" == x"true" ]; then
  api_ip_interface=eth2
fi

echo "${devices[@]}"
for dev in "${devices[@]}"; do
  interface=${dev%%.*}
  bridge=${dev##*.}
  # for the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interface
  # eth2 will only get local routes configuration
  ovs-docker.sh add-port "$bridge" "$interface" "haproxy-$CLUSTER_NAME"
  nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-$CLUSTER_NAME")" \
    /sbin/dhclient -v \
    -pf "/var/run/dhclient.$interface.pid" \
    -lf "/var/lib/dhcp/dhclient.$interface.lease" "$interface"
  
  if [ "$bridge" = "br-int" ]; then
    nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-$CLUSTER_NAME")" \
      /sbin/dhclient -6 -v \
      -pf "/var/run/dhclient.$interface.v6.pid" \
      -lf "/var/lib/dhcp/dhclient.$interface.v6.lease" "$interface"
  fi
done

echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "haproxy-$CLUSTER_NAME"

echo "Gather the IP Address for the new interface"

api_ip=$(nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-${CLUSTER_NAME}")" -n  \
  /sbin/ip -o -4 a list ${api_ip_interface} | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
if [ "${#api_ip}" -eq 0 ]; then
  echo "No IPv4 Address has been set for the external API VIP, failing"
  exit 1
fi

api_ip_v6=$(nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-${CLUSTER_NAME}")" -n \
  /sbin/ip -o -6 a list ${api_ip_interface} | grep global | sed 's/.*inet6 \(.*\)\/[0-9]* scope global.*/\1/')
if [ "${#api_ip_v6}" -eq 0 ]; then
  echo "No global IPv6 Address has been set for the external API VIP, failing"
  exit 1
fi

printf "ingress_vip: %s\napi_vip: %s\ningress_vip_v6: %s\napi_vip_v6: %s" "$api_ip" "$api_ip" "$api_ip_v6" "$api_ip_v6" > "$BUILD_DIR/external_vips.yaml"
# TODO[disconnected/BM/IPI]
#if [ "$DISCONNECTED" == "true" ] && IPI; then
#  cp "$BUILD_DIR/vips.yaml" "$BUILD_DIR/external_vips.yaml"
#fi
EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips.yaml" "${SHARED_DIR}/"
