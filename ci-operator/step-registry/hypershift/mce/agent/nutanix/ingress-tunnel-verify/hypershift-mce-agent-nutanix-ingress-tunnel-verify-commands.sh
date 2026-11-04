#!/bin/bash

set -euo pipefail
set +x

# shellcheck source=/dev/null
source "$SHARED_DIR/nutanix_context.sh"
# shellcheck source=/dev/null
source "$SHARED_DIR/packet-conf.sh"
if [[ -f "$SHARED_DIR/proxy-conf.sh" ]]; then
  # The hosted API endpoint is reached through the existing CI proxy.
  # shellcheck source=/dev/null
  source "$SHARED_DIR/proxy-conf.sh"
fi

state_file="$SHARED_DIR/nutanix_ingress_tunnel_state.json"
ssh_config="$SHARED_DIR/nutanix_ingress_tunnel_ssh_config"
if [[ ! -s "$state_file" || ! -s "$ssh_config" ]]; then
  echo "The lease-owned ingress tunnel has not been set up."
  exit 1
fi
state=$(cat "$state_file")
lease=$(jq -er '.lease' <<< "$state")
vip=$(jq -er '.vip' <<< "$state")
iface=$(jq -er '.interface' <<< "$state")
host_tunnel_ip=$(jq -er '.hostTunnelIP' <<< "$state")
gateway_ip=$(jq -er '.gatewayIP' <<< "$state")
stage=$(jq -er '.stage' <<< "$state")
expected_interface="wgnx$(printf '%s' "$lease" | sha256sum | cut -c1-8)"
if [[ "$lease" != "${NUTANIX_QUOTA_SLICE:-}" || "$vip" != "$INGRESS_VIP" ||
      "$stage" != ready || "$IP" != "$(jq -r '.hostIP' <<< "$state")" ||
      "$iface" != "$expected_interface" ||
      ! "$host_tunnel_ip" =~ ^[0-9.]+$ || ! "$gateway_ip" =~ ^[0-9.]+$ ]]; then
  echo "The ingress tunnel state does not match the Nutanix lease and proxy host."
  exit 1
fi

export KUBECONFIG="$SHARED_DIR/nested_kubeconfig"
mkdir -p "$ARTIFACT_DIR"
deadline=$((SECONDS + 900))

while :; do
  service_json=$(oc get service metallb-ingress -n openshift-ingress -o json 2>/dev/null || true)
  service_vip=$(jq -r '.status.loadBalancer.ingress[0].ip // empty' <<< "$service_json")
  endpoints_json=$(oc get endpoints metallb-ingress -n openshift-ingress --ignore-not-found -o json 2>/dev/null || true)
  ready_backends=0
  if [[ -n "$endpoints_json" ]]; then
    ready_backends=$(jq -r '[.subsets[]?.addresses[]?] | length' <<< "$endpoints_json")
  fi
  if [[ "$service_vip" == "$vip" && "$ready_backends" -gt 0 ]]; then break; fi
  if (( SECONDS >= deadline )); then
    echo "MetalLB ingress did not acquire $vip with ready router backends."
    exit 1
  fi
  sleep 15
done
printf 'MetalLB Service VIP: %s; ready router endpoints: %s\n' "$service_vip" "$ready_backends" \
  > "$ARTIFACT_DIR/nutanix-ingress-vip.txt"

canary_host=
while (( SECONDS < deadline )); do
  canary_json=$(oc get route canary -n openshift-ingress-canary -o json 2>/dev/null || true)
  canary_host=$(jq -r \
    '[.status.ingress[]? | select(.routerName == "default") | .host // empty] | first // empty' \
    <<< "$canary_json")
  if [[ -n "$canary_host" ]]; then break; fi
  sleep 15
done
if [[ ! "$canary_host" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "The ingress canary Route has no valid hostname for the default router."
  exit 1
fi

resolved_vip=$(ssh "${SSHOPTS[@]}" "root@$IP" getent ahostsv4 "$canary_host" |
  awk 'NR == 1 {print $1}')
if [[ "$resolved_vip" != "$vip" ]]; then
  echo "The proxy host resolves the canary Route to $resolved_vip instead of $vip."
  exit 1
fi

route_output=$(ssh "${SSHOPTS[@]}" "root@$IP" ip -4 route get "$vip")
printf '%s\n' "$route_output" > "$ARTIFACT_DIR/nutanix-ingress-proxy-route.txt"
if [[ " $route_output " != *" dev $iface "* ||
      " $route_output " != *" src $host_tunnel_ip "* ]]; then
  echo "The proxy host does not route the ingress VIP through its WireGuard interface."
  exit 1
fi

handshake=$(ssh "${SSHOPTS[@]}" "root@$IP" wg show "$iface" latest-handshakes | awk '{print $2; exit}')
if [[ ! "$handshake" =~ ^[0-9]+$ ]] || (( handshake == 0 || $(date +%s) - handshake >= 120 )); then
  echo "The proxy host has no recent WireGuard handshake with the gateway."
  exit 1
fi
ssh "${SSHOPTS[@]}" "root@$IP" wg show "$iface" transfer \
  > "$ARTIFACT_DIR/nutanix-ingress-wireguard-transfer.txt"
printf 'Most recent handshake: %s\n' "$handshake" \
  > "$ARTIFACT_DIR/nutanix-ingress-wireguard-handshake.txt"

gateway_route=$(ssh -F "$ssh_config" nutanix-ingress-gateway ip -4 route get "$vip")
printf '%s\n' "$gateway_route" > "$ARTIFACT_DIR/nutanix-ingress-gateway-route.txt"
if [[ " $gateway_route " == *" dev $iface "* ]]; then
  echo "The gateway would send the VIP back into WireGuard instead of its worker NIC."
  exit 1
fi
if [[ " $gateway_route " != *" src $gateway_ip "* ]]; then
  echo "The gateway does not use its worker-subnet address to reach the VIP."
  exit 1
fi
ssh -F "$ssh_config" nutanix-ingress-gateway \
  'sudo systemctl is-active --quiet hypershift-nutanix-ingress-firewall.service'

test_request() {
  local location=$1 result
  case "$location" in
    gateway)
      result=$(ssh -F "$ssh_config" nutanix-ingress-gateway bash -s -- \
        "$canary_host" "$vip" <<'REMOTE'
set -euo pipefail
curl -kfsS --connect-timeout 5 --max-time 12 --noproxy '*' \
  --resolve "$1:443:$2" -o /dev/null -w '%{http_code}' "https://$1/"
REMOTE
      ) || return 1
      ;;
    proxy-direct)
      result=$(ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
        "$canary_host" "$vip" <<'REMOTE'
set -euo pipefail
curl -kfsS --connect-timeout 5 --max-time 12 --noproxy '*' \
  --resolve "$1:443:$2" -o /dev/null -w '%{http_code}' "https://$1/"
REMOTE
      ) || return 1
      ;;
    proxy-squid)
      result=$(ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- "$canary_host" <<'REMOTE'
set -euo pipefail
curl -kfsS --connect-timeout 5 --max-time 12 --proxy http://127.0.0.1:8213 \
  --noproxy '' -o /dev/null -w '%{http_code}' "https://$1/"
REMOTE
      ) || return 1
      ;;
  esac
  [[ "$result" =~ ^2[0-9][0-9]$ || "$result" =~ ^3[0-9][0-9]$ ]] || return 1
  printf '%s: HTTP %s\n' "$location" "$result" >> "$ARTIFACT_DIR/nutanix-ingress-canary-http.txt"
}

test_http_port() {
  local location=$1 result
  case "$location" in
    gateway)
      result=$(ssh -F "$ssh_config" nutanix-ingress-gateway bash -s -- \
        "$canary_host" "$vip" <<'REMOTE'
set -euo pipefail
curl -ksS --connect-timeout 5 --max-time 12 --noproxy '*' \
  --resolve "$1:80:$2" -o /dev/null -w '%{http_code}' "http://$1/"
REMOTE
      ) || return 1
      ;;
    proxy-direct)
      result=$(ssh "${SSHOPTS[@]}" "root@$IP" bash -s -- \
        "$canary_host" "$vip" <<'REMOTE'
set -euo pipefail
curl -ksS --connect-timeout 5 --max-time 12 --noproxy '*' \
  --resolve "$1:80:$2" -o /dev/null -w '%{http_code}' "http://$1/"
REMOTE
      ) || return 1
      ;;
  esac
  [[ "$result" =~ ^[1-5][0-9][0-9]$ ]] || return 1
  printf '%s: HTTP %s on port 80\n' "$location" "$result" \
    >> "$ARTIFACT_DIR/nutanix-ingress-canary-http.txt"
}

while :; do
  if test_request gateway && test_request proxy-direct && test_request proxy-squid &&
     test_http_port gateway && test_http_port proxy-direct; then break; fi
  if (( SECONDS >= deadline )); then
    echo "The canary Route did not respond through the gateway, direct proxy route, and Squid."
    exit 1
  fi
  sleep 15
done
ssh -F "$ssh_config" nutanix-ingress-gateway \
  'sudo nft list table ip hcp_nutanix_ingress_tunnel' \
  > "$ARTIFACT_DIR/nutanix-ingress-gateway-nft.txt"

ingress_deadline=$((SECONDS + 300))
while :; do
  ingress_json=$(oc get clusteroperator ingress -o json 2>/dev/null || true)
  ingress_conditions=$(jq -r \
    '[.status.conditions[]? | select(.type == "Available" or .type == "Degraded") |
      "\(.type)=\(.status)"] | join(" ")' <<< "$ingress_json")
  canary_json=$(oc get ingresscontroller default -n openshift-ingress-operator -o json 2>/dev/null || true)
  canary_condition=$(jq -r \
    '[.status.conditions[]? | select(.type == "CanaryChecksSucceeding") | .status] |
      first // empty' <<< "$canary_json")
  if [[ "$ingress_conditions" == *"Available=True"* &&
        "$ingress_conditions" == *"Degraded=False"* &&
        "$canary_condition" == True ]]; then break; fi
  if (( SECONDS >= ingress_deadline )); then
    printf 'ClusterOperator: %s; CanaryChecksSucceeding: %s\n' \
      "$ingress_conditions" "${canary_condition:-unknown}" \
      > "$ARTIFACT_DIR/nutanix-ingress-operator-condition.txt"
    echo "The ingress operator did not report CanaryChecksSucceeding=True and healthy ClusterOperator conditions."
    exit 1
  fi
  sleep 15
done
printf 'ClusterOperator: %s; CanaryChecksSucceeding: %s\n' \
  "$ingress_conditions" "$canary_condition" \
  > "$ARTIFACT_DIR/nutanix-ingress-operator-condition.txt"

# The shared MetalLB step skips its original waits for this workflow until the
# VIP tunnel and the ingress canary are healthy. Restore its MCE readiness gate
# before the conformance chain starts.
if [[ -z "${PROW_JOB_ID:-}" ]]; then
  echo "PROW_JOB_ID is required to identify the hosted ManagedCluster."
  exit 1
fi
managed_cluster_name=$(printf '%s' "$PROW_JOB_ID" | sha256sum | cut -c1-20)
export KUBECONFIG="$SHARED_DIR/kubeconfig"
managed_deadline=$((SECONDS + 600))
while :; do
  if oc wait "managedcluster/$managed_cluster_name" --for='condition=ManagedClusterJoined' --timeout=10s >/dev/null 2>&1 &&
     oc wait "managedcluster/$managed_cluster_name" --for='condition=ManagedClusterConditionAvailable' --timeout=10s >/dev/null 2>&1 &&
     oc wait "managedcluster/$managed_cluster_name" --for='condition=HubAcceptedManagedCluster' --timeout=10s >/dev/null 2>&1; then
    break
  fi
  if (( SECONDS >= managed_deadline )); then
    oc get "managedcluster/$managed_cluster_name" -o jsonpath='{.status.conditions}' \
      > "$ARTIFACT_DIR/nutanix-managedcluster-conditions.txt" 2>/dev/null || true
    echo "ManagedCluster $managed_cluster_name did not become Joined, Available, and HubAccepted."
    exit 1
  fi
  sleep 10
done
oc get "managedcluster/$managed_cluster_name" -o jsonpath='{.status.conditions}' \
  > "$ARTIFACT_DIR/nutanix-managedcluster-conditions.txt" 2>/dev/null || true
printf 'Verified %s through the gateway, proxy-host route, and Squid; ingress canary and ManagedCluster are healthy.\n' \
  "$canary_host"
