#!/bin/bash

set -euo pipefail
set +x

STATE_FILE="$SHARED_DIR/nutanix_worker_dns_state.json"
if [[ ! -s "$STATE_FILE" ]]; then
  exit 0
fi

source "$SHARED_DIR/packet-conf.sh"
state=$(cat "$STATE_FILE")
cluster=$(jq -er '.cluster' <<<"$state")
subnet_uuid=$(jq -er '.subnetUUID' <<<"$state")
subnet_name=$(jq -er '.subnetName' <<<"$state")
lease=$(jq -er '.lease' <<<"$state")
bind_ip=$(jq -er '.bindIP' <<<"$state")
advertise_ip=$(jq -er '.advertisedIP' <<<"$state")
client_cidr=$(jq -er '.clientCIDR' <<<"$state")
original_options=$(jq -cS '.originalOptions' <<<"$state")
target_options=$(jq -cS '.targetOptions' <<<"$state")
original_servers=$(jq -ncS --argjson options "$original_options" '($options // {}).domain_name_server_list // []')
target_servers=$(jq -ncS --argjson options "$target_options" '$options.domain_name_server_list')

if [[ "$lease" != "${NUTANIX_QUOTA_SLICE:-}" || ! "$cluster" =~ ^[a-z0-9-]+$ ||
      ! "$subnet_uuid" =~ ^[0-9a-fA-F-]{36}$ || ! "$bind_ip" =~ ^[0-9.]+$ ||
      ! "$advertise_ip" =~ ^[0-9.]+$ || ! "$client_cidr" =~ ^[0-9./]+$ ]]; then
  echo "Worker DNS cleanup state does not match this Nutanix lease."
  exit 1
fi

auth_file=/var/run/vault/nutanix/secrets.sh
if [[ ! -r "$auth_file" ]]; then
  echo "Nutanix credentials are required to restore DHCP before removing the resolver."
  exit 1
fi
declare prism_central_host prism_central_port prism_central_username prism_central_password
source "$auth_file"
for variable in prism_central_host prism_central_port prism_central_username prism_central_password; do
  if [[ -z "${!variable:-}" ]]; then
    echo "Required Nutanix credential field $variable is empty."
    exit 1
  fi
done
pc_url="https://$prism_central_host:$prism_central_port"

function prism() {
  local method=$1
  local path=$2
  if [[ "$method" == GET ]]; then
    curl --silent --show-error --fail --insecure --max-time 30 \
      --user "$prism_central_username:$prism_central_password" "$pc_url/api/nutanix/v3/$path"
  else
    curl --silent --show-error --fail --insecure --max-time 30 \
      --user "$prism_central_username:$prism_central_password" -H 'Content-Type: application/json' \
      -X "$method" "$pc_url/api/nutanix/v3/$path" --data-binary @-
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
          echo "DHCP DNS restoration failed: $(jq -r '.error_detail // .progress_message // .status' <<<"$task_json")"
          return 1
          ;;
      esac
    fi
    sleep 10
  done
  echo "Timed out waiting for DHCP DNS restoration task $task_uuid."
  return 1
}

current_subnet=$(prism GET "subnets/$subnet_uuid")
if [[ $(jq -r '.metadata.uuid // empty' <<<"$current_subnet") != "$subnet_uuid" ||
      $(jq -r '.spec.name // empty' <<<"$current_subnet") != "$subnet_name" ]]; then
  echo "The leased subnet no longer matches the worker DNS cleanup state."
  exit 1
fi
current_servers=$(jq -cS '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$current_subnet")
if [[ "$current_servers" == "$target_servers" ]]; then
  subnet_response=$(jq --argjson original "$original_options" '
    {api_version,metadata,spec} |
    if (($original // {}) | has("domain_name_server_list")) then
      .spec.resources.ip_config.dhcp_options.domain_name_server_list = $original.domain_name_server_list
    else
      del(.spec.resources.ip_config.dhcp_options.domain_name_server_list) |
      if .spec.resources.ip_config.dhcp_options == {} and $original == null then
        del(.spec.resources.ip_config.dhcp_options)
      else . end
    end
  ' <<<"$current_subnet" |
    prism PUT "subnets/$subnet_uuid")
  wait_for_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$subnet_response")"
  restored=false
  for attempt in $(seq 1 24); do
    updated_subnet=$(prism GET "subnets/$subnet_uuid")
    if [[ $(jq -cS '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$updated_subnet") == "$original_servers" ]]; then
      restored=true
      break
    fi
    sleep 5
  done
  if [[ "$restored" != true ]]; then
    echo "The leased subnet still advertises worker DNS; leaving the host resolver running."
    exit 1
  fi
elif jq -e --arg ip "$advertise_ip" \
  '.spec.resources.ip_config.dhcp_options.domain_name_server_list // [] | index($ip) != null' \
  <<<"$current_subnet" >/dev/null; then
  echo "The leased subnet's DHCP options changed but still advertise $advertise_ip; leaving the host resolver running."
  exit 1
else
  echo "The leased subnet no longer advertises $advertise_ip; leaving its changed DHCP options untouched."
fi

ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- "$cluster" "$bind_ip" "$client_cidr" <<'EOF'
set -euo pipefail

cluster=$1
bind_ip=$2
client_cidr=$3
state_dir=/etc/hypershift-nutanix-worker-dns
config_file="$state_dir/$cluster.conf"
marker_file="$state_dir/$cluster.state"
unit="hypershift-nutanix-worker-dns-$cluster.service"
unit_file="/etc/systemd/system/$unit"

if [[ ! -e "$marker_file" ]]; then
  if [[ -e "$config_file" || -e "$unit_file" ]]; then
    echo "Worker DNS files exist without a matching run marker; refusing to remove them."
    exit 1
  fi
  exit 0
fi
read -r marker_cluster marker_bind marker_clients zone < "$marker_file"
if [[ "$marker_cluster" != "$cluster" || "$marker_bind" != "$bind_ip" ||
      "$marker_clients" != "$client_cidr" || ! "$zone" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "The baremetal worker DNS marker does not match this run."
  exit 1
fi

if [[ -e "$unit_file" ]]; then
  systemctl disable --now "$unit" || true
  if systemctl is-active --quiet "$unit"; then
    echo "The worker DNS service is still running; refusing to remove its files."
    exit 1
  fi
fi
firewall-cmd --state >/dev/null
for protocol in udp tcp; do
  allow_rule="rule priority=\"-100\" family=\"ipv4\" source address=\"$client_cidr\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
  deny_rule="rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
  for rule in "$allow_rule" "$deny_rule"; do
    if firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
      firewall-cmd --zone="$zone" --remove-rich-rule="$rule"
    fi
    if firewall-cmd --permanent --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
      firewall-cmd --permanent --zone="$zone" --remove-rich-rule="$rule"
    fi
  done
done
rm -f "$config_file" "$unit_file" "$marker_file"
systemctl daemon-reload
rmdir "$state_dir" 2>/dev/null || true
EOF

rm -f "$STATE_FILE"
printf 'Restored leased subnet DHCP DNS and removed the run-scoped baremetal resolver.\n'
