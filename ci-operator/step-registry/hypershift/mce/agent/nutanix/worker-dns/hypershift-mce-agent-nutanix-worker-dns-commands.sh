#!/bin/bash

set -euo pipefail
set +x

source "$SHARED_DIR/packet-conf.sh"
source "$SHARED_DIR/nutanix_context.sh"

CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
BASE_DOMAIN=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get dns cluster -o jsonpath='{.spec.baseDomain}')
STATE_FILE="$SHARED_DIR/nutanix_worker_dns_state.json"
TUNNEL_STATE_FILE="$SHARED_DIR/nutanix_ingress_tunnel_state.json"

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

if [[ ! -s "$TUNNEL_STATE_FILE" || ! -s "$SHARED_DIR/nutanix_ingress_tunnel_ssh_config" ]]; then
  echo "The Nutanix ingress tunnel must be ready before configuring worker DNS."
  exit 1
fi
tunnel_state=$(<"$TUNNEL_STATE_FILE")
if ! jq -e --arg lease "$NUTANIX_QUOTA_SLICE" --arg subnet "$SUBNET_UUID" \
  --arg vip "$INGRESS_VIP" --arg host "$IP" '
    .stage == "ready" and .lease == $lease and .subnetUUID == $subnet and
    .vip == $vip and .hostIP == $host
  ' <<<"$tunnel_state" >/dev/null; then
  echo "The Nutanix ingress tunnel does not match this lease, subnet, and proxy host."
  exit 1
fi
bind_ip=$(jq -er '.hostTunnelIP' <<<"$tunnel_state")
advertise_ip=$(jq -er '.gatewayIP' <<<"$tunnel_state")
client_ip=$(jq -er '.gatewayTunnelIP' <<<"$tunnel_state")
tunnel_interface=$(jq -er '.interface' <<<"$tunnel_state")
client_cidr="$client_ip/32"
if [[ ! "$tunnel_interface" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
  echo "The Nutanix ingress tunnel has an invalid WireGuard interface."
  exit 1
fi
gateway_route=$(ssh -F "$SHARED_DIR/nutanix_ingress_tunnel_ssh_config" \
  nutanix-ingress-gateway ip -4 route get "$INGRESS_VIP")
gateway_current_ip=$(awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}' <<<"$gateway_route")
if [[ "$gateway_current_ip" != "$advertise_ip" ]]; then
  echo "The Nutanix gateway's subnet IP changed before the discovery ISO was created."
  exit 1
fi

management_ip=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get nodes -l node-role.kubernetes.io/worker= \
  -o json | jq -r '[.items[].status.addresses[]? | select(.type == "InternalIP") | .address | select(test("^[0-9.]+$"))] | first // empty')
upstream=${NUTANIX_DNS_UPSTREAM:-127.0.0.1}
for address in "$management_ip" "$INGRESS_VIP" "$bind_ip" "$advertise_ip" "$client_ip" "$upstream"; do
  if ! valid_ipv4 "$address"; then
    echo "Worker DNS requires valid IPv4 management, ingress, bind, advertised, and upstream addresses."
    exit 1
  fi
done
if [[ "$bind_ip" == "$upstream" || "$advertise_ip" == "$upstream" ||
      "$bind_ip" == "$IP" || "$advertise_ip" == "$IP" || "$bind_ip" == "$advertise_ip" ]]; then
  echo "Worker DNS must bind to the host tunnel IP and advertise a distinct Nutanix gateway IP."
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
  --arg clientCIDR "$client_cidr" --arg tunnelInterface "$tunnel_interface" \
  '{cluster:$cluster,subnetUUID:$subnet,subnetName:$subnetName,lease:$lease,
    bindIP:$bind,advertisedIP:$advertised,clientCIDR:$clientCIDR,tunnelInterface:$tunnelInterface}' \
  > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$CLUSTER_NAME" "$BASE_DOMAIN" "$bind_ip" "$upstream" "$management_ip" "$INGRESS_VIP" \
  "$client_cidr" "$tunnel_interface" <<'EOF'
set -euo pipefail

cluster=$1
base_domain=$2
bind_ip=$3
upstream=$4
management_ip=$5
ingress_vip=$6
client_cidr=$7
tunnel_interface=$8
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
if [[ "$interface" != "$tunnel_interface" ]]; then
  echo "The DNS bind address $bind_ip is not assigned to the run's WireGuard interface."
  exit 1
fi
firewall-cmd --state >/dev/null
zone=$(firewall-cmd --get-zone-of-interface="$interface" 2>/dev/null || true)
if [[ -z "$zone" || "$zone" == "no zone" ]]; then
  zone=$(firewall-cmd --get-default-zone)
fi
for protocol in udp tcp; do
  deny_rule="rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
  allow_rule="rule priority=\"-100\" family=\"ipv4\" source address=\"$client_cidr\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  for rule in "$allow_rule" "$deny_rule"; do
    if firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 ||
      firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
      echo "A worker DNS firewall rule already exists; refusing to adopt it."
      exit 1
    fi
  done
done

install -d -m 700 "$state_dir"
printf '%s %s %s %s\n' "$cluster" "$bind_ip" "$client_cidr" "$zone" > "$marker_file"
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
# Keep TCP clients in child processes so an idle client cannot block DNS for workers.
ExecStart=$dnsmasq_binary --keep-in-foreground --conf-file=$config_file
RuntimeMaxSec=26h

[Install]
WantedBy=multi-user.target
UNIT

for protocol in udp tcp; do
  allow_rule="rule priority=\"-100\" family=\"ipv4\" source address=\"$client_cidr\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  deny_rule="rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
  firewall-cmd --zone="$zone" --add-rich-rule="$allow_rule" --timeout=27h
  firewall-cmd --zone="$zone" --add-rich-rule="$deny_rule" --timeout=27h
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
printf 'Worker DNS listens on %s:53 in firewall zone %s for tunnel peer %s.\n' "$bind_ip" "$zone" "$client_cidr"
EOF
printf 'Configured worker DNS through Nutanix gateway %s:53 without exposing the baremetal host IP or changing DHCP on subnet %s; verify UDP and TCP 53 from a Nutanix worker.\n' \
  "$advertise_ip" "$SUBNET_NAME"
