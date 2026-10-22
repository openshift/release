#!/bin/bash

set -euo pipefail
set +x

source "$SHARED_DIR/packet-conf.sh"
source "$SHARED_DIR/nutanix_context.sh"

CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
BASE_DOMAIN=$(oc --kubeconfig="$SHARED_DIR/kubeconfig" get dns cluster -o jsonpath='{.spec.baseDomain}')
STATE_FILE="$SHARED_DIR/nutanix_worker_dns_state.json"

if [[ "$SUBNET_NAME" != "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "Refusing to change DHCP on subnet $SUBNET_NAME: it is not the leased subnet ${NUTANIX_QUOTA_SLICE:-<unset>}."
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

function valid_cidr() {
  local address=${1%/*}
  local prefix=${1#*/}
  [[ "$1" == */* && "$prefix" =~ ^[0-9]{1,2}$ ]] &&
    valid_ipv4 "$address" && (( 10#$prefix >= 8 && 10#$prefix <= 32 ))
}

function prism() {
  local method=$1
  local path=$2
  if [[ "$method" == GET ]]; then
    curl --silent --show-error --fail --insecure --max-time 30 \
      --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" "$NUTANIX_PC_URL/api/nutanix/v3/$path"
  else
    curl --silent --show-error --fail --insecure --max-time 30 \
      --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" -H 'Content-Type: application/json' \
      -X "$method" "$NUTANIX_PC_URL/api/nutanix/v3/$path" --data-binary @-
  fi
}

function wait_for_task() {
  local task_uuid=$1
  local task_json task_status
  [[ -n "$task_uuid" ]] || return 0
  for attempt in $(seq 1 60); do
    if task_json=$(prism GET "tasks/$task_uuid" 2>/dev/null); then
      task_status=$(jq -r '.status // empty' <<<"$task_json")
      case "$task_status" in
        SUCCEEDED) return 0 ;;
        FAILED|ABORTED)
          echo "DHCP DNS update failed: $(jq -r '.error_detail // .progress_message // .status' <<<"$task_json")"
          return 1
          ;;
      esac
    fi
    sleep 10
  done
  echo "Timed out waiting for DHCP DNS task $task_uuid."
  return 1
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

subnet_json=$(prism GET "subnets/$SUBNET_UUID")
if [[ $(jq -r '.metadata.uuid // empty' <<<"$subnet_json") != "$SUBNET_UUID" ||
      $(jq -r '.spec.name // empty' <<<"$subnet_json") != "$SUBNET_NAME" ]]; then
  echo "The leased subnet no longer matches the Nutanix context."
  exit 1
fi
subnet_prefix=$(jq -r '.spec.resources.ip_config.prefix_length // empty' <<<"$subnet_json")
client_cidr=${NUTANIX_DNS_CLIENT_CIDR:-$SUBNET_IP/$subnet_prefix}
if ! valid_cidr "$client_cidr"; then
  echo "Set NUTANIX_DNS_CLIENT_CIDR to the IPv4 CIDR from which the baremetal host sees worker DNS queries."
  exit 1
fi
original_options=$(jq -cS '.spec.resources.ip_config.dhcp_options // null' <<<"$subnet_json")
if ! jq -e 'type == "null" or (type == "object" and ((.domain_name_server_list // []) | type == "array" and all(.[]; type == "string")))' \
  <<<"$original_options" >/dev/null; then
  echo "The leased subnet has an invalid DHCP DNS server list."
  exit 1
fi
if jq -e --arg ip "$advertise_ip" '(.domain_name_server_list // []) | index($ip) != null' \
  <<<"$original_options" >/dev/null; then
  echo "The leased subnet already advertises $advertise_ip; refusing to adopt existing DNS configuration."
  exit 1
fi
target_options=$(jq -ncS --argjson original "$original_options" --arg ip "$advertise_ip" \
  '($original // {}) | .domain_name_server_list = [$ip]')

umask 077
jq -n --arg cluster "$CLUSTER_NAME" --arg subnet "$SUBNET_UUID" --arg subnetName "$SUBNET_NAME" \
  --arg lease "$NUTANIX_QUOTA_SLICE" --arg bind "$bind_ip" --arg advertised "$advertise_ip" \
  --arg clients "$client_cidr" --argjson original "$original_options" --argjson target "$target_options" \
  '{cluster:$cluster,subnetUUID:$subnet,subnetName:$subnetName,lease:$lease,bindIP:$bind,advertisedIP:$advertised,clientCIDR:$clients,originalOptions:$original,targetOptions:$target}' \
  > "$STATE_FILE.tmp"
mv "$STATE_FILE.tmp" "$STATE_FILE"

ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$CLUSTER_NAME" "$BASE_DOMAIN" "$bind_ip" "$upstream" "$management_ip" "$INGRESS_VIP" "$client_cidr" <<'EOF'
set -euo pipefail

cluster=$1
base_domain=$2
bind_ip=$3
upstream=$4
management_ip=$5
ingress_vip=$6
client_cidr=$7
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
ExecStart=$dnsmasq_binary --no-daemon --conf-file=$config_file
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT

for protocol in udp tcp; do
  deny_rule="rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
  allow_rule="rule priority=\"-100\" family=\"ipv4\" source address=\"$client_cidr\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  firewall-cmd --permanent --zone="$zone" --add-rich-rule="$deny_rule"
  firewall-cmd --zone="$zone" --add-rich-rule="$deny_rule"
  firewall-cmd --permanent --zone="$zone" --add-rich-rule="$allow_rule"
  firewall-cmd --zone="$zone" --add-rich-rule="$allow_rule"
done
systemctl daemon-reload
systemctl enable --now "$unit"
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
printf 'Worker DNS listens on %s:53 in firewall zone %s for %s.\n' "$bind_ip" "$zone" "$client_cidr"
EOF

current_subnet=$(prism GET "subnets/$SUBNET_UUID")
if [[ $(jq -cS '.spec.resources.ip_config.dhcp_options // null' <<<"$current_subnet") != "$original_options" ]]; then
  echo "The leased subnet's DHCP options changed during host DNS setup; refusing to overwrite them."
  exit 1
fi
subnet_response=$(jq --argjson target "$target_options" \
  '{api_version,metadata,spec} | .spec.resources.ip_config.dhcp_options = $target' <<<"$current_subnet" |
  prism PUT "subnets/$SUBNET_UUID")
wait_for_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$subnet_response")"
advertised=false
for attempt in $(seq 1 24); do
  updated_subnet=$(prism GET "subnets/$SUBNET_UUID")
  if jq -e --arg ip "$advertise_ip" \
    '.spec.resources.ip_config.dhcp_options.domain_name_server_list == [$ip]' \
    <<<"$updated_subnet" >/dev/null; then
    advertised=true
    break
  fi
  sleep 5
done
if [[ "$advertised" != true ]]; then
  echo "The leased subnet did not advertise the baremetal DNS address through DHCP option 6."
  exit 1
fi

printf 'Advertised worker DNS %s on leased subnet %s; verify UDP and TCP 53 from a Nutanix worker.\n' \
  "$advertise_ip" "$SUBNET_NAME"
