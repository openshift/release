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

BUILD_USER=ci-op
BUILD_ID="${NAMESPACE}"

MC=""
APISRV=""
INGRESS80=""
INGRESS443=""
echo "Filling the load balancer targets..."
if [ "${IPI}" == "true" ]; then
  API_VIP="$(yq .api_vip "$SHARED_DIR/vips.yaml")"
  MC="server api_vip $API_VIP:22623 check inter 1s"
  APISRV="server api_vip $API_VIP:6443 check inter 1s"
  INGRESS80="server api_vip $API_VIP:80 check inter 1s"
  INGRESS443="server api_vip $API_VIP:443 check inter 1s"
else
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
      INGRESS80="
        server $name $ip:80 check inter 1s"
      INGRESS443="
        server $name $ip:443 check inter 1s"
    fi
  done
fi
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
stats show-desc Stats for $BUILD_USER-$BUILD_ID cluster
stats auth admin:$BUILD_USER-$BUILD_ID
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
        rfc3442-classless-static-routes, ntp-servers;

# Assuming eth1 will be the interface with the default gateway route
interface "eth1" {
    also request routers, domain-name, domain-name-servers, domain-search,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers;
}
'

echo "Pushing the configuration and starting the load balancer in the auxiliary host..."

timeout -s 9 10m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${BUILD_ID}" "${IPI}" "${DISCONNECTED}" "'${HAPROXY}'"  "'${DHCLIENT}'"  << 'EOF'
set -o nounset
set -o errexit
set -o pipefail

BUILD_ID="${1}"
BUILD_USER=ci-op
IPI="${2}"
DISCONNECTED="${3}"
HAPROXY="${4}"
DHCLIENT="${5}"
BUILD_DIR="/var/builds/${BUILD_ID}"
HAPROXY_DIR="$BUILD_DIR/haproxy"

mkdir -p "$HAPROXY_DIR"
echo -e "${HAPROXY}" >> "$HAPROXY_DIR/haproxy.cfg"
echo -e "${DHCLIENT}" >> "$HAPROXY_DIR/dhclient.conf"

echo "Create and start HAProxy container..."
docker run --name "haproxy-$BUILD_ID" -d --restart=on-failure \
  -v "$HAPROXY_DIR/haproxy.cfg:/etc/haproxy.cfg" \
  -v "$HAPROXY_DIR/dhclient.conf:/etc/dhcp/dhclient.conf" \
  --network none \
  quay.io/openshifttest/haproxy:armbm

echo "Setting the network interfaces in the HAProxy container"

# Unmount resolv.conf to let the custom network configuration able to modify it
nsenter -m -u -n -i -p -t "$(docker inspect -f '{{.State.Pid}}' "haproxy-${BUILD_ID}")" \
  /bin/umount /etc/resolv.conf

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
  /usr/local/bin/ovs-docker add-port "$bridge" "$interface" "haproxy-$BUILD_ID"
  nsenter -m -u -n -i -p -t "$(docker inspect -f '{{ .State.Pid }}' "haproxy-$BUILD_ID")" \
    /sbin/dhclient -v \
    -pf "/var/run/dhclient.$interface.pid" \
    -lf "/var/lib/dhcp/dhclient.$interface.lease" "$interface"
done
echo "Sending HUP to HAProxy to trigger the configuration reload..."
docker kill --signal HUP "haproxy-$BUILD_ID"

echo "Gather the IP Address for the new interface"
# IPI connected only
[ ${IPI} == "true" ] && cp "$BUILD_DIR/vips.yaml" "$BUILD_DIR/external_vips.yaml"
# IPI disconnected and UPI
if [ "${IPI}" != "true" ] || [ "${DISCONNECTED}" == "true" ]; then
  api_ip=$(nsenter -m -u -n -i -p -t "$(docker inspect -f '{{ .State.Pid }}' "haproxy-${BUILD_ID}")" -n  \
    /sbin/ip -o -4 a list eth1 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
  if [ "${#api_ip}" -eq 0 ]; then
    echo "No IP Address has been set for the external API VIP, failing"
    exit 1
  fi
  printf "ingress_vip: %s\napi_vip: %s" "$api_ip" "$api_ip" > "$BUILD_DIR/external_vips.yaml"
fi

EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${NAMESPACE}/external_vips.yaml" "${SHARED_DIR}/"
