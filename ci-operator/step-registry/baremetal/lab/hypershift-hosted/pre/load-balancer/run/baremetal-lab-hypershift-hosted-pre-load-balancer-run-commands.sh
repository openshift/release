#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# NOTE: This is the name of the provisioning cluster that we use as the folder to store information in the bastion
# for both the provisioning and hosted cluster.
# Keep this script in sync with the one in the baremetal/lab/pre/load-balancer directory

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"
HAPROXY="$(<"${SHARED_DIR}"/haproxy-hypershift-hosted.cfg)"

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
HAPROXY_DIR="$BUILD_DIR/haproxy-hypershift-hosted"

mkdir -p "$HAPROXY_DIR"
echo -e "${HAPROXY}" >> "$HAPROXY_DIR/haproxy.cfg"
echo -e "${DHCLIENT}" >> "$HAPROXY_DIR/dhclient.conf"

echo "Create and start HAProxy container for the hypershift-hosted cluster..."
podman run --name "haproxy-$CLUSTER_NAME-hypershift-hosted" -d --restart=on-failure \
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
  ovs-docker.sh add-port "$bridge" "$interface" "haproxy-$CLUSTER_NAME-hypershift-hosted"
  nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-$CLUSTER_NAME-hypershift-hosted")" \
    /sbin/dhclient -v \
    -pf "/var/run/dhclient.$interface.pid" \
    -lf "/var/lib/dhcp/dhclient.$interface.lease" "$interface"
  
  if [ "$bridge" = "br-int" ]; then
    nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-$CLUSTER_NAME-hypershift-hosted")" \
      /sbin/dhclient -6 -v \
      -pf "/var/run/dhclient.$interface.v6.pid" \
      -lf "/var/lib/dhcp/dhclient.$interface.v6.lease" "$interface"
  fi
done

echo "Sending HUP to HAProxy to trigger the configuration reload..."
podman kill --signal HUP "haproxy-$CLUSTER_NAME-hypershift-hosted"

echo "Gather the IP Address for the new interface"

api_ip=$(nsenter -m -u -n -i -p -t "$(podman inspect -f '{{ .State.Pid }}' "haproxy-${CLUSTER_NAME}-hypershift-hosted")" -n  \
  /sbin/ip -o -4 a list eth1 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/')
if [ "${#api_ip}" -eq 0 ]; then
  echo "No IP Address has been set for the external hypershift-hosted load balancer, failing"
  exit 1
fi
printf "ingress_vip: %s\napi_vip: %s" "$api_ip" "$api_ip" > "$BUILD_DIR/external_vips_hypershift_hosted.yaml"

EOF

echo "Syncing back the external_vips.yaml file"
scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/$(<"${SHARED_DIR}/cluster_name")/external_vips_hypershift_hosted.yaml" "${SHARED_DIR}/"
