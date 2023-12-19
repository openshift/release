#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

MC=""
APISRV=""
INGRESS80=""
INGRESS443=""
echo "Filling the load balancer targets..."
num_workers="$(yq e '[.[] | select(.name|test("worker"))]|length' "$SHARED_DIR/hosts.yaml")"
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [[ "$name" =~ bootstrap* ]] || [[ "$name" =~ master* ]]; then
    MC="$MC
      server $name $ip:22623 check inter 1s"
    APISRV="$APISRV
      server $name $ip:6443 check inter 1s"
  fi
  if [ "$num_workers" -eq 0 ] || [[ "$name" =~ worker* ]]; then
    INGRESS80="$INGRESS80
      server $name $ip:80 check inter 1s"
    INGRESS443="$INGRESS443
      server $name $ip:443 check inter 1s"
  fi
done
echo "Generating the template..."
HAPROXY="
global
log         127.0.0.1 local2
pidfile     /var/run/haproxy.pid
daemon
defaults
mode                    http
maxconn                 4000
log                     global
option                  dontlognull
option http-server-close
option                  redispatch
retries                 3
timeout http-request    10s
timeout queue           1m
timeout connect         10s
timeout client          1m
timeout server          1m
timeout http-keep-alive 10s
timeout check           10s
maxconn                 3000
frontend stats
bind *:1936
mode            http
log             global
maxconn 10
stats enable
stats hide-version
stats refresh 30s
stats show-node
stats show-desc Stats for $CLUSTER_NAME cluster
stats auth admin:$CLUSTER_NAME
stats uri /stats
listen api-server-6443
    bind *:6443
    mode tcp
$APISRV
listen machine-config-server-22623
    bind *:22623
    mode tcp
$MC
listen ingress-router-80
    bind *:80
    mode tcp
    balance source
$INGRESS80
listen ingress-router-443
    bind *:443
    mode tcp
    balance source
$INGRESS443
"

echo "Templating for HAProxy done..."

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
if [ x"${DISCONNECTED}" != x"true" ]; then
  devices=( eth1.br-ext eth2.br-int )
else
  devices=( eth1.br-int )
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
done
echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "haproxy-$CLUSTER_NAME"

echo "Gather the IP Address for the new interface"
api_ip=$(nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-${CLUSTER_NAME}")" -n  \
  /sbin/ip -o -4 a list eth1 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
if [ "${#api_ip}" -eq 0 ]; then
  echo "No IP Address has been set for the external API VIP, failing"
  exit 1
fi
printf "ingress_vip: %s\napi_vip: %s" "$api_ip" "$api_ip" > "$BUILD_DIR/external_vips.yaml"

EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips.yaml" "${SHARED_DIR}/"
