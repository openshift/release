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
lease=$(jq -er '.lease' <<<"$state")
bind_ip=$(jq -er '.bindIP' <<<"$state")
client_cidr=$(jq -r '.clientCIDR // empty' <<<"$state")

if [[ "$lease" != "${NUTANIX_QUOTA_SLICE:-}" || ! "$cluster" =~ ^[a-z0-9-]+$ ||
      ! "$bind_ip" =~ ^[0-9.]+$ || ( -n "$client_cidr" && ! "$client_cidr" =~ ^[0-9./]+$ ) ]]; then
  echo "Worker DNS cleanup state does not match this Nutanix lease."
  exit 1
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
read -r marker_cluster marker_bind marker_client_or_zone marker_zone < "$marker_file"
marker_matches=true
if [[ -n "$client_cidr" ]]; then
  zone=$marker_zone
  [[ "$marker_client_or_zone" == "$client_cidr" ]] || marker_matches=false
else
  zone=$marker_client_or_zone
  [[ -z "$marker_zone" ]] || marker_matches=false
fi
if [[ "$marker_cluster" != "$cluster" || "$marker_bind" != "$bind_ip" ||
      "$marker_matches" != true || ! "$zone" =~ ^[a-zA-Z0-9_-]+$ ]]; then
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
  if [[ -n "$client_cidr" ]]; then
    rules=(
      "rule priority=\"-100\" family=\"ipv4\" source address=\"$client_cidr\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept"
      "rule priority=\"-90\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" drop"
    )
  else
    rules=("rule priority=\"-100\" family=\"ipv4\" destination address=\"$bind_ip\" port port=\"53\" protocol=\"$protocol\" accept")
  fi
  for rule in "${rules[@]}"; do
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
printf 'Removed the run-scoped baremetal worker DNS resolver without changing subnet DHCP.\n'
