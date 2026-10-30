#!/bin/bash

set -euo pipefail
set +x

source "$SHARED_DIR/packet-conf.sh"
source "$SHARED_DIR/nutanix_context.sh"

CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
BASE_DOMAIN=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get dns cluster -o jsonpath='{.spec.baseDomain}')
STATE_FILE="$SHARED_DIR/nutanix_worker_dns_state.json"

if [[ -z "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "NUTANIX_QUOTA_SLICE is required from the workflow lease."
  exit 1
fi
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ || ! "$BASE_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "The HostedCluster name or base domain is invalid for dnsmasq."
  exit 1
fi
if [[ -e "$STATE_FILE" ]]; then
  echo "Worker DNS state already exists; clean up the previous setup before retrying."
  exit 1
fi

function valid_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] &&
    awk -F. 'NF == 4 { for (octet_index = 1; octet_index <= 4; octet_index++) if ($octet_index > 255) exit 1; exit 0 } { exit 1 }' <<<"$1"
}

function prism() {
  local path=$1
  curl --silent --show-error --fail --insecure --max-time 30 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" "$NUTANIX_PC_URL/api/nutanix/v3/$path"
}

management_ip=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get nodes -l node-role.kubernetes.io/worker= \
  -o json | jq -r '[.items[].status.addresses[]? | select(.type == "InternalIP") | .address | select(test("^[0-9.]+$"))] | first // empty')
bind_ip=${NUTANIX_DNS_BIND_IP:-${IP:-}}
advertise_ip=${NUTANIX_DNS_ADVERTISE_IP:-${IP:-}}
upstream=${NUTANIX_DNS_UPSTREAM:-127.0.0.1}
for address in "$management_ip" "$INGRESS_VIP" "$bind_ip" "$advertise_ip" "$upstream"; do
  if ! valid_ipv4 "$address"; then
    echo "Worker DNS requires valid IPv4 management, ingress, bind, advertised, and upstream addresses."
    exit 1
  fi
done
if [[ "$bind_ip" == "$upstream" || "$advertise_ip" == "$upstream" ]]; then
  echo "The worker DNS upstream cannot be the worker-facing resolver."
  exit 1
fi
if [[ "$bind_ip" == 0.* || "$bind_ip" == 127.* || "$bind_ip" == 169.254.* ||
      "$advertise_ip" == 0.* || "$advertise_ip" == 127.* || "$advertise_ip" == 169.254.* ]]; then
  echo "The worker-facing DNS addresses must be routable non-loopback IPv4 addresses."
  exit 1
fi

subnet_json=$(prism "subnets/$SUBNET_UUID")
if [[ $(jq -r '.metadata.uuid // empty' <<<"$subnet_json") != "$SUBNET_UUID" ||
      $(jq -r '.spec.name // empty' <<<"$subnet_json") != "$SUBNET_NAME" ]]; then
  echo "The selected Nutanix subnet no longer matches the Nutanix context."
  exit 1
fi
umask 077
jq -n --arg cluster "$CLUSTER_NAME" --arg subnet "$SUBNET_UUID" --arg subnetName "$SUBNET_NAME" \
  --arg lease "$NUTANIX_QUOTA_SLICE" --arg bind "$bind_ip" --arg advertised "$advertise_ip" \
  '{cluster:$cluster,subnetUUID:$subnet,subnetName:$subnetName,lease:$lease,bindIP:$bind,advertisedIP:$advertised}' \
  > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$CLUSTER_NAME" "$BASE_DOMAIN" "$bind_ip" "$upstream" "$management_ip" "$INGRESS_VIP" <<'EOF'
set -euo pipefail

cluster=$1
base_domain=$2
bind_ip=$3
upstream=$4
management_ip=$5
ingress_vip=$6
state_dir=/etc/hypershift-nutanix-worker-dns
config_file="$state_dir/$cluster.conf"
marker_file="$state_dir/$cluster.state"
unit="hypershift-nutanix-worker-dns-$cluster.service"
unit_file="/etc/systemd/system/$unit"

if [[ -e "$config_file" || -e "$marker_file" || -e "$unit_file" ]]; then
  echo "Run-scoped worker DNS files already exist on the baremetal host; refusing to adopt them."
  exit 1
fi
interface=$(ip -o -4 addr show | awk -v address="$bind_ip" '$3 == "inet" { split($4, fields, "/"); if (fields[1] == address) { print $2; exit } }')
interface=${interface%%@*}
if [[ -z "$interface" ]]; then
  echo "The DNS bind address $bind_ip is not assigned to the baremetal host. Set NUTANIX_DNS_BIND_IP to a local address and arrange port 53 forwarding if needed."
  exit 1
fi
firewall-cmd --state >/dev/null
zone=$(firewall-cmd --get-zone-of-interface="$interface" 2>/dev/null || true)
if [[ -z "$zone" || "$zone" == "no zone" ]]; then
  zone=$(firewall-cmd --get-default-zone)
fi
for protocol in udp tcp; do
  deny_rule="rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
  allow_rule="rule priority=\"-100\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  for rule in "$allow_rule" "$deny_rule"; do
    if firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
      firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
      echo "A worker DNS firewall rule already exists; refusing to adopt it."
      exit 1
    fi
  done
done

install -d -m 700 "$state_dir"
printf '%s %s %s\n' "$cluster" "$bind_ip" "$zone" > "$marker_file"
chmod 600 "$marker_file"
cat > "$config_file" <<CONF
port=53
no-resolv
no-hosts
bind-interfaces
listen-address=$bind_ip
server=$upstream
address=/api.$cluster.$base_domain/$management_ip
address=/api-int.$cluster.$base_domain/$management_ip
address=/.apps.$cluster.$base_domain/$ingress_vip
CONF
chmod 600 "$config_file"
dnsmasq --test --conf-file="$config_file"
dnsmasq_binary=$(command -v dnsmasq)
cat > "$unit_file" <<UNIT
[Unit]
Description=Run-scoped Nutanix worker DNS for $cluster
After=network-online.target firewalld.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=$dnsmasq_binary --no-daemon --conf-file=$config_file
RuntimeMaxSec=26h

[Install]
WantedBy=multi-user.target
UNIT

for protocol in udp tcp; do
  allow_rule="rule priority=\"-100\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  firewall-cmd --zone="$zone" --add-rich-rule="$allow_rule" --timeout=24h
done
systemctl daemon-reload
systemctl start "$unit"
systemctl is-active --quiet "$unit"
if command -v dig >/dev/null; then
  api_answer=$(dig +short +time=2 +tries=1 @"$bind_ip" "api.$cluster.$base_domain" A)
  api_int_answer=$(dig +short +time=2 +tries=1 @"$bind_ip" "api-int.$cluster.$base_domain" A)
  apps_answer=$(dig +short +time=2 +tries=1 @"$bind_ip" "console-openshift-console.apps.$cluster.$base_domain" A)
  forwarded_answer=$(dig +short +time=2 +tries=1 @"$bind_ip" registry.redhat.io A)
  if [[ "$api_answer" != "$management_ip" || "$api_int_answer" != "$management_ip" || "$apps_answer" != "$ingress_vip" ]]; then
    echo "The host-bound resolver did not return the expected API, API-int, and apps addresses."
    exit 1
  fi
  if [[ -z "$forwarded_answer" ]]; then
    echo "The host-bound resolver did not forward an unrelated DNS query."
    exit 1
  fi
fi
printf 'Worker DNS listens on %s:53 in firewall zone %s without a source-IP restriction.\n' "$bind_ip" "$zone"
EOF
printf 'Configured worker DNS at %s:53 without changing DHCP on shared subnet %s; verify UDP and TCP 53 from a Nutanix worker.\n' \
  "$advertise_ip" "$SUBNET_NAME"
