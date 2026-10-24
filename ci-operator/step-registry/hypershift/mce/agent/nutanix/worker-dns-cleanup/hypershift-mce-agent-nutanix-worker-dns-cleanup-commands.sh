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
client_cidr=$(jq -er '.clientCIDR' <<<"$state")

if [[ "$lease" != "${NUTANIX_QUOTA_SLICE:-}" || ! "$cluster" =~ ^[a-z0-9-]+$ ||
      ! "$bind_ip" =~ ^[0-9.]+$ || ! "$client_cidr" =~ ^[0-9./]+$ ]]; then
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
printf 'Removed the run-scoped baremetal worker DNS resolver without changing subnet DHCP.\n'
