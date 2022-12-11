#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh IPI=false
fi

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BUILD_USER=ci-op
BUILD_ID="${NAMESPACE}"

MC=`if [ "${IPI}" != "true" ]; then 
  for bmhost in $(yq e -o=j -I=0 '.[] | select(.name == "master*")' "${SHARED_DIR}/hosts.yaml"); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    echo "    server $name $ip:6443 check inter 1s"
  done
else
   echo "    server API_VIP 1.1.1.1:6443 check inter 1s"
fi`

APISRV=`for bmhost in $(yq e -o=j -I=0 '.[] | select(.name == "master*")' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  echo "    server $name $ip:22623 check inter 1s"
done`

INGRESS80=`for bmhost in $(yq e -o=j -I=0 '.[] | select(.name == "worker*")' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  echo "    server $name $ip:80 check inter 1s"
done`

INGRESS443=`for bmhost in $(yq e -o=j -I=0 '.[] | select(.name == "worker*")' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  echo "    server $name $ip:443 check inter 1s jad"
done`

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
$MC
listen machine-config-server-22623
    bind *:22623
    mode tcp
$APISRV
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

DHCLIENT="
# Configuration file for /sbin/dhclient.
#
# This is a sample configuration file for dhclient. See dhclient.conf's
#       man page for more information about the syntax of this file
#       and a more comprehensive list of the parameters understood by
#       dhclient.
#
# Normally, if the DHCP server provides reasonable information and does
#       not leave anything out (like the domain name, for example), then
#       few changes must be made to this file, if any.
#

option rfc3442-classless-static-routes code 121 = array of unsigned integer 8;

send host-name = gethostname();
request subnet-mask, broadcast-address, time-offset, host-name,
        netbios-name-servers, netbios-scope, interface-mtu,
        rfc3442-classless-static-routes, ntp-servers;

# Assuming eth1 will be the interface with the default gateway route
interface 'eth1' {
    also request routers, domain-name, domain-name-servers, domain-search,
        dhcp6.name-servers, dhcp6.domain-search, dhcp6.fqdn, dhcp6.sntp-servers;
}

#send dhcp-client-identifier 1:0:a0:24:ab:fb:9c;
#send dhcp-lease-time 3600;
#supersede domain-name "fugue.com home.vix.com";
#prepend domain-name-servers 127.0.0.1;
#require subnet-mask, domain-name-servers;
#timeout 60;
#retry 60;
#reboot 10;
#select-timeout 5;
#initial-interval 2;
#script '/sbin/dhclient-script';
#media '-link0 -link1 -link2', 'link0 link1';
#reject 192.33.137.209;

#alias {
#  interface 'eth0';
#  fixed-address 192.5.5.213;
#  option subnet-mask 255.255.255.255;
#}

#lease {
#  interface 'eth0';
#  fixed-address 192.33.137.200;
#  medium 'link0 link1';
#  option host-name 'andare.swiftmedia.com';
#  option subnet-mask 255.255.255.0;
#  option broadcast-address 192.33.137.255;
#  option routers 192.33.137.250;
#  option domain-name-servers 127.0.0.1;
#  renew 2 2000/1/12 00:00:01;
#  rebind 2 2000/1/12 00:00:01;
#  expire 2 2000/1/12 00:00:01;
#}
"

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${BUILD_ID}" "${IPI}" "${BUILD_USER}" "${HAPROXY}"  "${DHCLIENT}"  << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
set -o allexport

BUILD_ID="${1}"
IPI="${2}"
BUILD_USER=${3}"

cp /var/builds/$BUILD_ID/vips.yaml /var/builds/$BUILD_ID/external_vips.yaml

# shellcheck disable=SC2174
mkdir -m 755 -p "/var/builds/$BUILD_ID/haproxy"

echo -e "${4}" >> var/builds/$BUILD_ID/haproxy/haproxy.cfg
echo -e "${5}" >> var/builds/$BUILD_ID/haproxy/dhclient.conf

# Create and start HAProxy container
docker run --name "haproxy-$BUILD_ID" --restart=on-failure \
  -v "/var/builds/$BUILD_ID/haproxy/haproxy.cfg:/etc/haproxy.cfg" \
  -v "/var/builds/$BUILD_ID/haproxy/dhclient.conf:/etc/dhcp/dhclient.conf" \
  quay.io/openshifttest/haproxy:armbm

# for the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interface
# eth2 will only get local routes configuration
set -x
# Unmount resolv.conf to let custom network conf able to modify it
nsenter -m -u -n -i -p -t $(docker inspect -f '{{ '{{' }}.State.Pid {{ '}}' }}' haproxy-{{ BUILD_ID }}) \
/bin/umount /etc/resolv.conf

devices=(eth1.br-ext eth2.br-int)
if [ x"${DISCONNECTED}" != x"true" ]; then
  for dev in ${devices[@]}; do
    interface=$(echo $dev | cut -f1 -d.)
    bridge=$(echo $dev | cut -f2 -d.)
    # for the given dhclient.conf, eth1 will also get default route, dns and other options usual for the main interface
    # eth2 will only get local routes configuration
    set -x
    /usr/local/bin/ovs-docker add-port $bridge $interface haproxy-$BUILD_ID
    nsenter -m -u -n -i -p -t $(docker inspect -f '{{ '{{' }}.State.Pid {{ '}}' }}' haproxy-$BUILD_ID) \
    /sbin/dhclient -v \
    -pf /var/run/dhclient.$interface.pid \
    -lf /var/lib/dhcp/dhclient.$interface.lease $interface
  done
else
  set -x
    /usr/local/bin/ovs-docker add-port br-int eth1 haproxy-$BUILD_ID
    nsenter -m -u -n -i -p -t $(docker inspect -f '{{ '{{' }}.State.Pid {{ '}}' }}' haproxy-$BUILD_ID) \
    /sbin/dhclient -v \
    -pf /var/run/dhclient.eth1.pid \
    -lf /var/lib/dhcp/dhclient.eth1.lease eth1

fi

# Gather the IP Address for the new interface
api_ip=nsenter -m -u -n -i -p -t $(docker inspect -f '{{ '{{' }}.State.Pid {{ '}}' }}' haproxy-{{ BUILD_ID }}) -n  \
/sbin/ip -o -4 a list eth1 | sed 's/.*inet \(.*\)\/[0-9]* brd.*$/\1/'

vips="
ingress_vip: $api_ip
api_vip: $api_ip
"
echo $vips > external_vips.yaml

docker kill --signal HUP "haproxy-$BUILD_ID"

EOF

scp "${SSHOPTS[@]}" "root@${AUX_HOST}:/var/builds/${NAMESPACE}/external_vips.yaml" "${SHARED_DIR}/"
