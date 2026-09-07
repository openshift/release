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

# User-managed / platform-none HAProxy owns the VIPs. Cluster-managed IPI must
# not bind bootstrap (.80.N / ::3:N) or cluster VIPs (.81/.82).
if [ "${LOAD_BALANCER_TYPE:-cluster-managed}" == "user-managed" ] || [ "${AGENT_PLATFORM_TYPE:-}" == "none" ]; then
  use_static_internal_ip=true
else
  use_static_internal_ip=false
fi

if [ "${use_static_internal_ip}" == "true" ]; then
  echo "Injecting static VIP assignments to eth2 (user-managed / platform-none)..."
  if [ "${ipv4_enabled}" == "true" ]; then
    if [ "${DISCONNECTED}" == "true" ]; then
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_API_IPV4"/22 dev eth2
      echo "Disconnected environment: Adding Ingress IP address to eth2 as alias..."
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_INGRESS_IPV4"/22 dev eth2
    else
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_INGRESS_IPV4"/22 dev eth2
    fi
  fi
  if [ "${ipv6_enabled}" == "true" ]; then
    if [ "${DISCONNECTED}" == "true" ]; then
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_API_IPV6"/64 dev eth2
      echo "Disconnected environment: Adding Ingress IPv6 address to eth2 as alias..."
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_INGRESS_IPV6"/64 dev eth2
    else
      nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "$INTERNAL_INGRESS_IPV6"/64 dev eth2
    fi
  fi
else
  # Cluster-managed IPI: HAProxy is only a client of the VIPs. Lab IPv4 DHCP is
  # static-only (dhcp-range=192.168.80.0,static), so eth2 cannot lease an address.
  # Do not bind .80.N / ::3:N (bootstrap) or .81/.82 (cluster VIPs). Host IDs in
  # this lab are <= 133; last-octet+100 stays in the /22 and off that range.
  echo "Injecting cluster-managed HAProxy eth2 addresses (not VIP, not bootstrap)..."
  if [ "${ipv4_enabled}" == "true" ]; then
    vip_last_octet="${INTERNAL_API_IPV4##*.}"
    haproxy_int_v4="192.168.80.$((vip_last_octet + 100))"
    if [ $((vip_last_octet + 100)) -gt 254 ]; then
      echo "Cannot derive HAProxy internal IPv4 from API VIP ${INTERNAL_API_IPV4}: last octet + 100 overflows."
      exit 1
    fi
    echo "Adding ${haproxy_int_v4}/22 on eth2 (API VIP last octet ${vip_last_octet} + 100)"
    nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "${haproxy_int_v4}"/22 dev eth2
  fi
  if [ "${ipv6_enabled}" == "true" ]; then
    # API VIP is ::1:N, ingress ::2:N, bootstrap ::3:N. Use ::4:N for HAProxy.
    haproxy_int_v6="${INTERNAL_API_IPV6/::1:/::4:}"
    echo "Adding ${haproxy_int_v6}/64 on eth2"
    nsenter -t "$CONTAINER_PID" -n /sbin/ip addr add "${haproxy_int_v6}"/64 dev eth2
  fi
fi
nsenter -t "$CONTAINER_PID" -n /sbin/ip link set eth2 up

# --- EXTERNAL IPv4 DHCP SERVICE ---
if [ "${ipv4_enabled}" == "true" ]; then
  if [ "${ipv6_enabled}" != "true" ]; then
    nsenter -t "$CONTAINER_PID" -n /sbin/sysctl -w net.ipv6.conf.eth1.disable_ipv6=1
  fi
  if [ "${DISCONNECTED}" != "true" ]; then
    echo "Launching isolated IPv4 DHCP client exclusively for eth1..."
    nsenter -m -u -n -i -p -t "$CONTAINER_PID" /sbin/dhclient -nw -v \
      -pf "/etc/haproxy/dhclient.v4.pid" \
      -lf "/etc/haproxy/dhclient.v4.lease" eth1 201>&-

    echo "Waiting for interfaces to obtain IPv4 addresses inside the container namespace..."
    for i in {1..60}; do
      if nsenter -t "$CONTAINER_PID" -n /sbin/ip -o -4 a list "${api_ip_interface}" | grep -q 'inet '; then
        echo "IPv4 network layer state successfully verified."
        break
      fi

      if [ "$i" -eq 60 ]; then
        echo "Timed out waiting for DHCP IPv4 assignment on eth1. Exiting."
        exit 1
      fi
      sleep 0.5
    done
  else
    echo "Disconnected environment active. Skipping external IPv4 DHCP."
  fi
else
  echo "IPv4 is disabled. Skipping IPv4 lease request."
fi

# --- EXTERNAL IPv6 DHCP SERVICE ---
if [ "${ipv6_enabled}" == "true" ]; then
  if [ "${DISCONNECTED}" != "true" ]; then
    echo "Waiting for eth1 IPv6 Link-Local address to stabilize..."
    for j in {1..20}; do
      if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth1 | grep -q 'inet6 fe80:' && \
         ! nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list eth1 | grep -q 'tentative'; then
        echo "eth1 IPv6 Link-Local interface is ready."
        break
      fi
      if [ "$j" -eq 20 ]; then
        echo "Timed out waiting for eth1 IPv6 Link-Local initialization. Exiting."
        exit 1
      fi
      sleep 0.5
    done

    echo "Waiting for SLAAC to automatically assign global IPv6 addresses inside the container namespace..."
    for i in {1..60}; do
      if nsenter -n -t "$CONTAINER_PID" /sbin/ip -o -6 a list "${api_ip_interface}" | grep global | grep -q 'inet6 '; then
        echo "IPv6 global network layer state successfully verified."
        break
      fi

      if [ "$i" -eq 60 ]; then
        echo "Timed out waiting for SLAAC auto-configuration on eth1. Exiting."
        exit 1
      fi
      sleep 0.5
    done
  else
    echo "Disconnected environment active. Disabling IPv6 tracking profiles."
    nsenter -t "$CONTAINER_PID" -n /sbin/sysctl -w net.ipv6.conf.eth1.disable_ipv6=1
  fi
else
  echo "IPv6 is disabled. Skipping SLAAC address allocation."
fi

cleanup
trap - EXIT INT TERM

echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "$CONTAINER_NAME"

# --- MERGED VARIABLE GATHERING BLOCK ---
echo "Gathering the IP Addresses for downstream tasks..."
api_ip=""
api_int_ip=""
api_ip_v6=""
api_int_ip_v6=""
ingress_vip=""
ingress_vip_v6=""

if [ "${ipv4_enabled:-false}" == "true" ]; then
  if [ "${DISCONNECTED}" == "true" ]; then
    api_ip="$INTERNAL_API_IPV4"
  else
    api_ip=$(nsenter -t "$CONTAINER_PID" -n /sbin/ip -o -4 a list ${api_ip_interface} | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
  fi
  api_int_ip="$api_ip"
  ingress_vip="$INTERNAL_INGRESS_IPV4"

  if [ "${#api_ip}" -eq 0 ]; then
    echo "No IPv4 Address has been mapped for the API VIP, failing."
    exit 1
  fi
fi

if [ "${ipv6_enabled:-false}" == "true" ]; then
  if [ "${DISCONNECTED}" == "true" ]; then
    api_ip_v6="$INTERNAL_API_IPV6"
  else
    api_ip_v6=$(nsenter -t "$CONTAINER_PID" -n /sbin/ip -o -6 a list ${api_ip_interface} | grep global | sed 's/.*inet6 \(.*\)\/[0-9]* scope global.*/\1/')
  fi
  api_int_ip_v6="$api_ip_v6"
  ingress_vip_v6="$INTERNAL_INGRESS_IPV6"

  if [ "${#api_ip_v6}" -eq 0 ]; then
    echo "No global IPv6 Address has been mapped for the API VIP, failing."
    exit 1
  fi
fi

printf "ingress_vip: %s\napi_vip: %s\ningress_vip_v6: %s\napi_vip_v6: %s\napi_int: %s\napi_int_v6: %s" "$ingress_vip" "$api_ip" "$ingress_vip_v6" "$api_ip_v6" "$api_int_ip" "$api_int_ip_v6" > "$BUILD_DIR/external_vips.yaml"
EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips.yaml" "${SHARED_DIR}/"
