#!/bin/bash

set -euo pipefail

tracing_enabled=false
if [[ $- == *x* ]]; then tracing_enabled=true; fi

state_file="$SHARED_DIR/nutanix_ingress_tunnel_state.json"
identity_file="$SHARED_DIR/nutanix_ingress_tunnel_identity.json"
ssh_config="$SHARED_DIR/nutanix_ingress_tunnel_ssh_config"
cleanup_context_if_complete() {
  if [[ -e "$SHARED_DIR/nutanix_destroy_complete" && ! -e "$state_file" &&
        ! -e "$SHARED_DIR/nutanix_worker_dns_state.json" &&
        ! -e "$SHARED_DIR/nutanix_squid_allowed_hosts" ]]; then
    rm -f "$identity_file" "$SHARED_DIR/nutanix_context.sh" \
      "$SHARED_DIR/nutanix_destroy_complete"
  fi
}
if [[ ! -e "$state_file" ]]; then
  cleanup_context_if_complete
  exit 0
fi
if [[ ! -s "$state_file" ]]; then
  echo "The tunnel state file is empty; retaining the Nutanix context for investigation."
  exit 1
fi
if [[ ! -s "$identity_file" ]]; then
  echo "The tunnel identity is missing; retaining the Nutanix context for investigation."
  exit 1
fi

# Disable tracing only while sourcing the host connection settings.
set +x
# shellcheck source=/dev/null
source "$SHARED_DIR/packet-conf.sh"
if [[ "$tracing_enabled" == true ]]; then set -x; fi
state=$(cat "$state_file")
identity=$(<"$identity_file")
lease=$(jq -er '.lease' <<< "$state")
job_id=$(jq -er '.prowJobID' <<< "$state")
vip=$(jq -er '.vip' <<< "$state")
subnet_uuid=$(jq -er '.subnetUUID' <<< "$state")
iface=$(jq -er '.interface' <<< "$state")
port=$(jq -er '.port' <<< "$state")
gateway_name=$(jq -er '.gatewayName' <<< "$state")
gateway_uuid=$(jq -r '.gatewayUUID // empty' <<< "$state")
gateway_task_uuid=$(jq -r '.gatewayTaskUUID // empty' <<< "$state")
image_name=$(jq -er '.imageName' <<< "$state")
image_uuid=$(jq -r '.imageUUID // empty' <<< "$state")
image_task_uuid=$(jq -r '.imageTaskUUID // empty' <<< "$state")
host_ip=$(jq -er '.hostIP' <<< "$state")
route_cidr=$(jq -er '.routeCIDR' <<< "$state")
firewall_zone=$(jq -r '.firewallZone // empty' <<< "$state")
stage=$(jq -er '.stage' <<< "$state")
if [[ -z "${PROW_JOB_ID:-}" ]] || ! jq -e \
  --arg lease "${NUTANIX_QUOTA_SLICE:-}" --arg job "$PROW_JOB_ID" \
  --arg subnet "$subnet_uuid" --arg vip "$vip" --arg iface "$iface" \
  --arg gateway "$gateway_name" --arg image "$image_name" '
    .schemaVersion == 1 and .lease == $lease and .prowJobID == $job and
    .subnetUUID == $subnet and .vip == $vip and
    .interface == $iface and .gatewayName == $gateway and .imageName == $image
  ' <<< "$identity" >/dev/null; then
  echo "The tunnel identity does not match this run or the recorded state."
  exit 1
fi
if [[ "$job_id" != "$PROW_JOB_ID" ||
      "$lease" != "${NUTANIX_QUOTA_SLICE:-}" || "$host_ip" != "$IP" ||
      ! "$iface" =~ ^wgnx[0-9a-f]{8}$ ||
      ! "$gateway_name" =~ ^hcp-nxwg-[0-9a-f]{8}-[0-9a-f]{8}$ ||
      "$gateway_name" != "hcp-nxwg-${iface#wgnx}-"* ||
      "$image_name" != "$gateway_name-rhcos" || ! "$port" =~ ^[0-9]+$ ||
      ! "$vip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ||
      "$route_cidr" != "$vip/32" ||
      ( -n "$firewall_zone" && ! "$firewall_zone" =~ ^[a-zA-Z0-9_-]+$ ) ||
      ( -n "$gateway_uuid" && ! "$gateway_uuid" =~ ^[0-9a-fA-F-]{36}$ ) ||
      ( -n "$gateway_task_uuid" && ! "$gateway_task_uuid" =~ ^[0-9a-fA-F-]{36}$ ) ||
      ( -n "$image_uuid" && ! "$image_uuid" =~ ^[0-9a-fA-F-]{36}$ ) ||
      ( -n "$image_task_uuid" && ! "$image_task_uuid" =~ ^[0-9a-fA-F-]{36}$ ) ]]; then
  echo "Tunnel cleanup state does not match this run's expected resources."
  exit 1
fi

# Leave the Prism resources and state intact if host cleanup cannot be verified.
# A later cleanup retry can then recover rather than leaving a blackhole route.
ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
  "$lease" "$vip" "$iface" "$port" "$firewall_zone" <<'REMOTE'
set -euo pipefail
lease=$1 vip=$2 iface=$3 port=$4 expected_zone=${5:-}
state_dir=/etc/hypershift-nutanix-ingress-tunnel
marker="$state_dir/$iface.state"
config="/etc/wireguard/$iface.conf"
key="/etc/wireguard/$iface.key"
unit="hypershift-nutanix-ingress-tunnel-$iface.service"
unit_file="/etc/systemd/system/$unit"
if [[ ! -e "$marker" ]]; then
  if [[ -e "$config" || -e "$key" || -e "$unit_file" ||
        -e "/sys/class/net/$iface" ]]; then
    echo "Proxy-host tunnel resources exist without the run marker; refusing deletion." >&2
    exit 1
  fi
  exit 0
fi
read -r marker_lease marker_vip marker_iface marker_port zone < "$marker"
if [[ "$marker_lease" != "$lease" || "$marker_vip" != "$vip" ||
      "$marker_iface" != "$iface" || "$marker_port" != "$port" ||
      ! "$zone" =~ ^(-|[a-zA-Z0-9_-]+)$ ||
      ( -n "$expected_zone" && "$zone" != "$expected_zone" ) ]]; then
  echo "The proxy-host tunnel marker does not match this lease." >&2
  exit 1
fi
if [[ -e "$unit_file" ]]; then
  systemctl stop "$unit" || true
  if systemctl is-active --quiet "$unit"; then
    echo "The run-owned WireGuard service is still active." >&2
    exit 1
  fi
  systemctl disable "$unit"
fi
if ip link show "$iface" >/dev/null 2>&1; then
  if [[ -e "$config" ]]; then
    wg-quick down "$iface"
  else
    echo "A WireGuard interface remains without its run-owned config." >&2
    exit 1
  fi
fi
route=$(ip -4 route show exact "$vip/32")
if [[ -n "$route" ]]; then
  if [[ " $route " != *" dev $iface "* ]]; then
    echo "The VIP has a route that is not owned by this tunnel." >&2
    exit 1
  fi
  ip route del "$vip/32" dev "$iface"
fi
if [[ "$zone" != '-' ]]; then
  firewall-cmd --state >/dev/null
  if firewall-cmd --zone="$zone" --query-port="$port/udp" >/dev/null 2>&1; then
    firewall-cmd --zone="$zone" --remove-port="$port/udp"
  fi
fi
rm -f "$config" "$key" "$unit_file" "$marker"
systemctl daemon-reload
rmdir "$state_dir" 2>/dev/null || true
REMOTE

if [[ ! -s "$SHARED_DIR/nutanix_context.sh" ]]; then
  echo "The Nutanix context is unavailable; retaining tunnel state for VM cleanup."
  exit 1
fi
# Disable tracing for the Prism credential source and all remaining API calls.
set +x
# shellcheck source=/dev/null
source "$SHARED_DIR/nutanix_context.sh"
if [[ "$vip" != "$INGRESS_VIP" || "$subnet_uuid" != "$SUBNET_UUID" ]]; then
  echo "The recorded subnet or VIP no longer matches the Nutanix context."
  exit 1
fi

prism_list() {
  curl --silent --show-error --fail --insecure --max-time 60 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST \
    "$NUTANIX_PC_URL/api/nutanix/v3/$1/list" \
    --data "{\"kind\":\"$2\",\"length\":1000}"
}

prism_get_with_code() {
  local kind=$1 uuid=$2 body=$3
  curl --silent --show-error --insecure --max-time 45 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -o "$body" -w '%{http_code}' \
    "$NUTANIX_PC_URL/api/nutanix/v3/$kind/$uuid"
}

recover_uuid() {
  local endpoint=$1 kind=$2 name=$3 response found
  for ((attempt = 1; attempt <= 12; attempt++)); do
    response=$(prism_list "$endpoint" "$kind")
    found=$(jq -r --arg name "$name" '[.entities[]? | select(.spec.name == $name) |
      .metadata.uuid] | unique | if length == 0 then "" elif length == 1 then .[0]
      else error("Ambiguous run-owned Prism resource name") end' <<< "$response")
    if [[ -n "$found" ]]; then printf '%s\n' "$found"; return 0; fi
    sleep 10
  done
  return 1
}

wait_absent() {
  local endpoint=$1 uuid=$2 code
  for ((attempt = 1; attempt <= 40; attempt++)); do
    code=$(prism_get_with_code "$endpoint" "$uuid" /dev/null)
    if [[ "$code" == 404 ]]; then return 0; fi
    if [[ "$code" != 200 ]]; then
      echo "Unexpected Prism status $code for $endpoint/$uuid."
      return 1
    fi
    sleep 15
  done
  return 1
}

wait_create_task() {
  local task=$1 body code status
  body=$(mktemp)
  for ((attempt = 1; attempt <= 36; attempt++)); do
    code=$(prism_get_with_code tasks "$task" "$body")
    if [[ "$code" == 200 ]]; then
      status=$(jq -r '.status // empty' "$body")
      case "$status" in
        SUCCEEDED|FAILED|ABORTED|CANCELLED) rm -f "$body"; return 0 ;;
      esac
    fi
    sleep 10
  done
  rm -f "$body"
  echo "Prism did not confirm a terminal state for creation task $task."
  return 1
}

delete_recorded() {
  local endpoint=$1 kind=$2 name=$3 uuid=$4 create_task=$5 code body
  if [[ -n "$create_task" ]]; then wait_create_task "$create_task"; fi
  if [[ -z "$uuid" ]]; then
    case "$endpoint:$stage" in
      vms:vm-create-requested|vms:vm-created|vms:host-route-active|vms:ready|\
      images:image-create-requested|images:image-created|images:vm-create-requested|\
      images:vm-created|images:host-route-active|images:ready) ;;
      *) return 0 ;;
    esac
    if ! uuid=$(recover_uuid "$endpoint" "$kind" "$name"); then
      echo "Prism did not prove that the requested $name is absent; retaining tunnel state for a cleanup retry."
      return 1
    fi
  fi
  body=$(mktemp)
  code=$(prism_get_with_code "$endpoint" "$uuid" "$body")
  if [[ "$code" == 404 ]]; then
    rm -f "$body"
    return 0
  fi
  if [[ "$code" != 200 || "$(jq -r '.spec.name // empty' "$body")" != "$name" ]]; then
    rm -f "$body"
    echo "The recorded $endpoint UUID does not identify this run's $name."
    return 1
  fi
  rm -f "$body"
  code=$(curl --silent --show-error --insecure --max-time 60 \
    --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" -X DELETE \
    -o /dev/null -w '%{http_code}' \
    "$NUTANIX_PC_URL/api/nutanix/v3/$endpoint/$uuid")
  if [[ "$code" != 200 && "$code" != 202 && "$code" != 204 && "$code" != 404 ]]; then
    echo "Prism rejected deletion of $endpoint/$uuid with HTTP $code."
    return 1
  fi
  if ! wait_absent "$endpoint" "$uuid"; then
    echo "Prism did not confirm deletion of $endpoint/$uuid."
    return 1
  fi
}

delete_recorded vms vm "$gateway_name" "$gateway_uuid" "$gateway_task_uuid"
delete_recorded images image "$image_name" "$image_uuid" "$image_task_uuid"
rm -f "$ssh_config" "$state_file"
cleanup_context_if_complete
printf 'Removed the lease-owned proxy-host tunnel, Nutanix gateway VM, and image for %s.\n' "$lease"
if [[ "$tracing_enabled" == true ]]; then set -x; fi
