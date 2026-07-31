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

timeout 10s ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "systemd-cat -t '${CLUSTER_NAME}' -p5 echo 'baremetal-lab-ipi-conf-load-balancer: Generating HAProxy configuration'" || true

API_VIP="$(yq .api_vip "$SHARED_DIR/vips.yaml")"
INGRESS_VIP="$(yq .ingress_vip "$SHARED_DIR/vips.yaml")"
API_VIP_V6="$(yq .api_vip_v6 "$SHARED_DIR/vips.yaml")"
INGRESS_VIP_V6="$(yq .ingress_vip_v6 "$SHARED_DIR/vips.yaml")"
SSH=""

for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ -z "$name" ] || [ -z "$ip" ] || [ -z "$ipv6" ] || [ -z "$host" ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi
  SSH="$SSH
    listen $name-ssh
    bind :::$((13000 + "$host"))
    mode tcp
    balance source
    server $name $ip:22 check inter 1s
    server $name-v6 [$ipv6]:22 check inter 1s"
done
echo "Generating the template..."
cat > "${SHARED_DIR}/haproxy.cfg" <<EOF
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
bind :::1936
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
    bind :::6443
    mode tcp
    server api $API_VIP:6443 check inter 1s
    server apiv6 [$API_VIP_V6]:6443 check inter 1s
listen machine-config-server-22623
    bind :::22623
    mode tcp
    server api $API_VIP:22623 check inter 1s
    server apiv6 [$API_VIP_V6]:22623 check inter 1s
listen ingress-router-80
    bind :::80
    mode tcp
    balance source
    server ingress $INGRESS_VIP:80 check inter 1s
    server ingressv6 [$INGRESS_VIP_V6]:80 check inter 1s
listen ingress-router-443
    bind :::443
    mode tcp
    balance source
    server ingress $INGRESS_VIP:443 check inter 1s
    server ingressv6 [$INGRESS_VIP_V6]:443 check inter 1s
$SSH
EOF

echo "Templating for HAProxy done..."

cat "${SHARED_DIR}/haproxy.cfg"
