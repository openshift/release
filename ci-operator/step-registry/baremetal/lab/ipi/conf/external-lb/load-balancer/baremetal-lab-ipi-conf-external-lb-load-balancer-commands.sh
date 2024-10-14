#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

MC=""
APISRV=""
INGRESS80=""
INGRESS443=""
IRONICSRV=""
INSPECTORSRV=""
SSH=""
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
    IRONICSRV="$IRONICSRV
      server $name $ip:6385 check inter 1s"
    INSPECTORSRV="$INSPECTORSRV
      server $name $ip:5050 check inter 1s"
  fi
  if [ "$num_workers" -eq 0 ] || [[ "$name" =~ worker* ]]; then
    INGRESS80="$INGRESS80
      server $name $ip:80 check inter 1s"
    INGRESS443="$INGRESS443
      server $name $ip:443 check inter 1s"
  fi
  SSH="$SSH
    listen $name-ssh
    bind :::$((13000 + "$host"))
    mode tcp
    balance source
    server $name $ip:22 check inter 1s
    server $name-v6 [$ipv6]:22 check inter 1s"
done
### FIXME temporary
MC="${MC}
      server bootstrap $(<"${SHARED_DIR}/ipi_bootstrap_ip_address"):22623 check inter 1s"
APISRV="${APISRV}
      server bootstrap $(<"${SHARED_DIR}/ipi_bootstrap_ip_address"):6443 check inter 1s"
IRONICSRV="${IRONICSRV}
      server bootstrap $(<"${SHARED_DIR}/ipi_bootstrap_ip_address"):6385 check inter 1s"
INSPECTORSRV="${INSPECTORSRV}
      server bootstrap $(<"${SHARED_DIR}/ipi_bootstrap_ip_address"):5050 check inter 1s"
echo "Generating the template..."

cat > "$SHARED_DIR/haproxy.cfg" <<EOF
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
$APISRV
listen machine-config-server-22623
    bind :::22623
    mode tcp
$MC
listen ingress-router-80
    bind :::80
    mode tcp
    balance source
$INGRESS80
listen ingress-router-443
    bind :::443
    mode tcp
    balance source
$INGRESS443
listen ironic-api-6385
    bind :::6385
    mode tcp
    balance source
$IRONICSRV
listen inspector-api-5050
    bind :::5050
    mode tcp
    balance source
$INSPECTORSRV
$SSH
EOF

echo "Templating for HAProxy done..."

cat "$SHARED_DIR/haproxy.cfg"