#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh IPI=false SELF_MANAGED_NETWORK=true \
      INTERNAL_NET_IP=192.168.90.1
fi

set -o nounset
set -o errexit
set -o pipefail

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BUILD_USER=ci-op
BUILD_ID="${NAMESPACE}"

# Generate haproxy.cfg
cat > haproxy.cfg << EOF
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
$(
if [ "${IPI}" != "true" ]; then
  for bmhost in $(yq e -o=j -I=0 '.[]' hosts.yaml); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    if [[ $name == *master* ]]; then
    echo "    server $name $ip:6443 check inter 1s"
    fi
  done
else
   echo "    server API_VIP 1.1.1.1:6443 check inter 1s"
fi
)
listen machine-config-server-22623
    bind *:22623
    mode tcp
$(
  for bmhost in $(yq e -o=j -I=0 '.[]' hosts.yaml); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    if [[ $name == *master* ]]; then
    echo "    server $name $ip:22623 check inter 1s"
    fi
  done
)
listen ingress-router-80
    bind *:80
    mode tcp
    balance source
$(
  for bmhost in $(yq e -o=j -I=0 '.[]' hosts.yaml); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    if [[ $name == *worker* ]]; then
    echo "    server $name $ip:80 check inter 1s"
    fi
  done
)
listen ingress-router-443
    bind *:443
    mode tcp
    balance source
$(
  for bmhost in $(yq e -o=j -I=0 '.[]' hosts.yaml); do
    # shellcheck disable=SC1090
    . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
    # shellcheck disable=SC2154
    if [[ $name == *worker* ]]; then
    echo "    server $name $ip:443 check inter 1s"
    fi
  done
)
EOF

# Generate dhclient.conf
cat > dhclient.conf << EOF
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
interface "eth1" {
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
#script "/sbin/dhclient-script";
#media "-link0 -link1 -link2", "link0 link1";
#reject 192.33.137.209;

#alias {
#  interface "eth0";
#  fixed-address 192.5.5.213;
#  option subnet-mask 255.255.255.255;
#}

#lease {
#  interface "eth0";
#  fixed-address 192.33.137.200;
#  medium "link0 link1";
#  option host-name "andare.swiftmedia.com";
#  option subnet-mask 255.255.255.0;
#  option broadcast-address 192.33.137.255;
#  option routers 192.33.137.250;
#  option domain-name-servers 127.0.0.1;
#  renew 2 2000/1/12 00:00:01;
#  rebind 2 2000/1/12 00:00:01;
#  expire 2 2000/1/12 00:00:01;
#}

EOF

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "${IPI}" << 'EOF'
set -o nounset
set -o errexit
set -o pipefail
set -o allexport

BUILD_USER=ci-op
BUILD_ID="${1}"
IPI="${2}"
set +o allexport

# shellcheck disable=SC2174
mkdir -m 755 -p "/var/builds/$BUILD_ID/haproxy"
EOF

echo "Uploading the haproxy.cfg file to the auxiliary host..."
scp "${SSHOPTS[@]}" haproxy.cfg "root@${AUX_HOST}:/var/builds/$NAMESPACE/haproxy"
scp "${SSHOPTS[@]}" dhclient.conf "root@${AUX_HOST}:/var/builds/$NAMESPACE/haproxy"
