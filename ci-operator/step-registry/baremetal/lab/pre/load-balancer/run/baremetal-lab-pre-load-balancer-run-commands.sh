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

LOAD_BALANCER_TYPE="${LOAD_BALANCER_TYPE:-cluster-managed}"
AGENT_PLATFORM_TYPE="${AGENT_PLATFORM_TYPE:-baremetal}"

timeout -s 9 21m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${CLUSTER_NAME}" "${DISCONNECTED}" "'${HAPROXY}'"  "'${DHCLIENT}'" "${ipv4_enabled:-false}" \
  "${ipv6_enabled:-false}" "${LOAD_BALANCER_TYPE:-}" "${AGENT_PLATFORM_TYPE:-}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${1}"
DISCONNECTED="${2}"
HAPROXY="${3}"
DHCLIENT="${4}"
ipv4_enabled="${5}"
ipv6_enabled="${6}"
LOAD_BALANCER_TYPE="${7}"
AGENT_PLATFORM_TYPE="${8}"

BUILD_DIR="/var/builds/${CLUSTER_NAME}"
HAPROXY_DIR="$BUILD_DIR/haproxy"

mkdir -p "$HAPROXY_DIR"
echo -e "${HAPROXY}" >> "$HAPROXY_DIR/haproxy.cfg"
echo -e "${DHCLIENT}" >> "$HAPROXY_DIR/dhclient.conf"

INTERNAL_API_IPV4=$(yq ".api_vip" $BUILD_DIR/vips.yaml)
INTERNAL_API_IPV6=$(yq ".api_vip_v6" $BUILD_DIR/vips.yaml)

INTERNAL_INGRESS_IPV4=$(yq ".ingress_vip" $BUILD_DIR/vips.yaml)
INTERNAL_INGRESS_IPV6=$(yq ".ingress_vip_v6" $BUILD_DIR/vips.yaml)

CONTAINER_NAME="haproxy-$CLUSTER_NAME"

MAC_ADDRESS_EXT=$(echo -n "${CLUSTER_NAME}-ETH1" | sha256sum | cut -c1-10 | sed 's/\(..\)/\1:/g; s/^/02:/; s/:$//')
MAC_ADDRESS_INT=$(echo -n "${CLUSTER_NAME}-ETH2" | sha256sum | cut -c1-10 | sed 's/\(..\)/\1:/g; s/^/02:/; s/:$//')

echo "Create and start HAProxy container..."
podman run --name "$CONTAINER_NAME" -d --restart=always \
  -v "$HAPROXY_DIR:/etc/haproxy:Z" \
  -v "$HAPROXY_DIR/haproxy.cfg:/etc/haproxy.cfg:Z" \
  -v "$HAPROXY_DIR/dhclient.conf:/etc/dhcp/dhclient.conf:Z" \
  --network none \
  quay.io/openshifttest/haproxy:armbm

echo "Setting the network interfaces in the HAProxy container"
CONTAINER_PID=$(podman inspect -f '{{ .State.Pid }}' "$CONTAINER_NAME")

devices=( eth1.br-ext eth2.br-int )
api_ip_interface=eth1
if [ "${DISCONNECTED}" == "true" ]; then
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

echo "Acquiring network lock $LOCK_FD ($LOCK) (waiting up to 20 minutes)"
if ! flock -w 1200 "$LOCK_FD"; then
    echo "Error: Failed to acquire network lock within 20 minutes."
    exit 1
fi
echo "Network lock acquired"

echo "Attaching all ports to the container..."
for dev in "${devices[@]}"; do
  interface=${dev%%.*}
  bridge=${dev##*.}

  if [ "$interface" == "eth1" ]; then
    ovs-docker.sh add-port "$bridge" "$interface" "$CONTAINER_NAME" --macaddress="$MAC_ADDRESS_EXT"
  else
    ovs-docker.sh add-port "$bridge" "$interface" "$CONTAINER_NAME" --macaddress="$MAC_ADDRESS_INT"
  fi
done

if [ "${ipv4_enabled:-false}" == "true" ]; then
  echo "Launching global IPv4 DHCP client..."
  nsenter -m -u -n -i -p -t "$CONTAINER_PID" \
    /sbin/dhclient -nw -v \
    -pf "/etc/haproxy/dhclient.v4.pid" \
    -lf "/etc/haproxy/dhclient.v4.lease" eth1 eth2 201>&-

  echo "Waiting for interfaces to obtain IPv4 addresses inside the container namespace..."
  for i in {1..60}; do
    if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -4 a list "${api_ip_interface}" | grep -q 'inet '; then
      if [ "${DISCONNECTED}" == "true" ] || nsenter -m -u -n -i -p -t "$CONTAINER_PID" /sbin/ip -o -4 a list eth2 | grep -q 'inet '; then
        echo "IPv4 addresses successfully assigned."
        break
      fi
    fi

    if [ "$i" -eq 60 ]; then
      echo "Timed out waiting for DHCP IPv4 assignment inside container. Exiting."
      exit 1
    fi
    sleep 0.5
  done
else
  echo "IPv4 is disabled. Skipping IPv4 lease request."
fi

if [ "${ipv6_enabled:-false}" == "true" ] && [[ " ${devices[*]} " == *" eth2.br-int "* ]]; then

  echo "Waiting for eth2 IPv6 Link-Local address to be ready..."
  for j in {1..20}; do
    # Using only -n namespace argument to guarantee stability
    if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth2 | grep -q 'inet6 fe80:' && \
       ! nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth2 | grep -q 'tentative'; then
      echo "eth2 IPv6 link-local interface is ready and available."
      break
    fi
    [ "$j" -eq 20 ] && { echo "Timed out waiting for eth2 link-local interface state. Exiting."; exit 1; }
    sleep 0.5
  done

  echo "Launching IPv6 DHCP client for eth2..."
  nsenter -m -u -n -i -p -t "$CONTAINER_PID" \
    /sbin/dhclient -6 -v \
    -cf /dev/null \
    -pf "/etc/haproxy/dhclient.eth2.v6.pid" \
    -lf "/etc/haproxy/dhclient.eth2.v6.lease" eth2 201>&-
  sleep 2
else
  echo "IPv6 is disabled or br-int is absent. Skipping IPv6 lease request."
fi

cleanup
trap - EXIT INT TERM

echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "$CONTAINER_NAME"

echo "Gather the IP Address for the new interface"
api_ip=""
if [ "${ipv4_enabled:-false}" == "true" ]; then
  api_ip=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" -n  \
    /sbin/ip -o -4 a list ${api_ip_interface} | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
  if [ "${#api_ip}" -eq 0 ]; then
    echo "No IPv4 Address has been set for the external API VIP, failing"
    exit 1
  fi
fi

api_ip_v6=""
if [ "${ipv6_enabled:-false}" == "true" ]; then
  echo "Waiting for ${api_ip_interface} global IPv6 address to be ready..."
  for i in {1..60}; do
    if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list ${api_ip_interface} | grep global | grep -q 'inet6' && \
       ! nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list ${api_ip_interface} | grep global | grep -q 'tentative'; then
      api_ip_v6=$(nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list ${api_ip_interface} | grep global | sed -n 's/.*inet6 \([^ ]*\)\/.*/\1/p' | head -n1)
      if [ -n "$api_ip_v6" ]; then
        echo "Global IPv6 address ready: $api_ip_v6"
        break
      fi
    fi
    if [ "$i" -eq 60 ]; then
      echo "No global IPv6 Address has been set for the external API VIP, failing"
      exit 1
    fi
    sleep 0.5
  done
fi

api_int_ip="$api_ip"
api_int_ip_v6="$api_ip_v6"

if [ x"${DISCONNECTED}" != x"true" ]; then
  if [ "${ipv4_enabled:-false}" == "true" ]; then
    api_int_ip=$(nsenter -m -u -n -i -p -t "$CONTAINER_PID" \
    /sbin/ip -o -4 a list eth2 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
    if [ "${#api_int_ip}" -eq 0 ]; then
      echo "No IPv4 Address has been set for internal api-int, failing"
      exit 1
    fi
  fi

  if [ "${ipv6_enabled:-false}" == "true" ]; then
    echo "Waiting for eth2 global IPv6 address to be ready..."
    for i in {1..60}; do
      if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth2 | grep global | grep -q 'inet6' && \
         ! nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth2 | grep global | grep -q 'tentative'; then
        api_int_ip_v6=$(nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth2 | grep global | sed -n 's/.*inet6 \([^ ]*\)\/.*/\1/p' | head -n1)
        if [ -n "$api_int_ip_v6" ]; then
          echo "Global IPv6 address ready on eth2: $api_int_ip_v6"
          break
        fi
      fi
      if [ "$i" -eq 60 ]; then
        echo "No global IPv6 Address has been set for internal IPv6 api-int, failing"
        exit 1
      fi
      sleep 0.5
    done
  fi
fi

printf "ingress_vip: %s\napi_vip: %s\ningress_vip_v6: %s\napi_vip_v6: %s\napi_int: %s\napi_int_v6: %s" "$api_ip" "$api_ip" "$api_ip_v6" "$api_ip_v6" "$api_int_ip" "$api_int_ip_v6" > "$BUILD_DIR/external_vips.yaml"
EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips.yaml" "${SHARED_DIR}/"
