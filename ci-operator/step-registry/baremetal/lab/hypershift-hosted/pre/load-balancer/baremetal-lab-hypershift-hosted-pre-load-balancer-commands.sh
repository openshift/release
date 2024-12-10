#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="$(<"${SHARED_DIR}/hostedcluster_name")"

MC=""
APISRV=""
INGRESS80=""
INGRESS443=""
KONNECTIVITY=""
OAUTH_SERVER=""
SSH=""
echo "Filling the load balancer targets..."
num_workers="$(yq e '[.[] | select(.name|test("worker-[0-9]"))]|length' "$SHARED_DIR/hosts.yaml")"
KUBE_API_PORT=$(<"$SHARED_DIR/hosted_kube-apiserver_port")
IGNITION_PORT=$(<"$SHARED_DIR/hosted_ignition-server-proxy_port")
KONNECTIVITY_PORT=$(<"$SHARED_DIR/hosted_konnectivity-server_port")
OAUTH_PORT=$(<"$SHARED_DIR/hosted_oauth-openshift_port")
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ] || [ ${#ipv6} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi

  # We use the additional workers implemented for heterogeneous clusters as nodes for the hypershift hosted cluster
  if [[ "$name" =~ worker-a-* ]]; then
    INGRESS80="$INGRESS80
      server $name $ip:30080 check inter 1s
      server $name-v6 [$ipv6]:30080 check inter 1s"
    INGRESS443="$INGRESS443
      server $name $ip:30443 check inter 1s
      server $name-v6 [$ipv6]:30443 check inter 1s"
  # num_workers<2 will cover SNO and other cases where master nodes can act as workers too
  elif [[ "$name" =~ worker-* ]] || [ "$num_workers" -lt 2 ]; then
     MC="$MC
       server $name $ip:${IGNITION_PORT} check inter 1s
       server $name-v6 [$ipv6]:${IGNITION_PORT} check inter 1s"
     APISRV="$APISRV
       server $name $ip:$KUBE_API_PORT check inter 1s
       server $name-v6 [$ipv6]:$KUBE_API_PORT check inter 1s"
     KONNECTIVITY="$KONNECTIVITY
       server $name $ip:${KONNECTIVITY_PORT} check inter 1s
       server $name-v6 [$ipv6]:${KONNECTIVITY_PORT} check inter 1s"
     OAUTH_SERVER="$OAUTH_SERVER
       server $name $ip:${OAUTH_PORT} check inter 1s
       server $name-v6 [$ipv6]:${OAUTH_PORT} check inter 1s"
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

cat > "$SHARED_DIR/haproxy-hypershift-hosted.cfg" <<EOF
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
listen api-server-$KUBE_API_PORT
    bind :::$KUBE_API_PORT
    mode tcp
$APISRV
listen machine-config-server-${IGNITION_PORT}
    bind :::${IGNITION_PORT}
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
listen oauth-${OAUTH_PORT}
    bind :::${OAUTH_PORT}
    mode tcp
${OAUTH_SERVER}
listen konnectivity-${KONNECTIVITY_PORT}
    bind :::${KONNECTIVITY_PORT}
    mode tcp
${KONNECTIVITY}
$SSH
EOF

echo "Templating for HAProxy done..."

cat "${SHARED_DIR}/haproxy-hypershift-hosted.cfg"
