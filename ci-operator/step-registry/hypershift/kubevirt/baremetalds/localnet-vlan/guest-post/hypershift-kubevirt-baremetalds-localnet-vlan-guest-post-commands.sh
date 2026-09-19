#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOCALNET_VLAN_EGRESS_ENABLE="${LOCALNET_VLAN_EGRESS_ENABLE:-true}"

if [[ "${ATTACH_DEFAULT_NETWORK:-}" != "localnet-vlan" ]]; then
  echo "Skipping localnet-vlan guest post-config (ATTACH_DEFAULT_NETWORK=${ATTACH_DEFAULT_NETWORK:-})"
  exit 0
fi

localnet_vlan_nested_oc() {
  local nested_kc="${SHARED_DIR}/nested_kubeconfig"
  KUBECONFIG="${nested_kc}" oc --request-timeout=15s "$@"
}

localnet_vlan_wait_nested_api_ready() {
  local nested_kc="${SHARED_DIR}/nested_kubeconfig"
  local wait_sec="${LOCALNET_VLAN_GUEST_API_WAIT_TIMEOUT:-600}"
  local max_attempts=$((wait_sec / 10))
  local attempt

  if [[ ! -f "${nested_kc}" ]]; then
    echo "ERROR: nested kubeconfig missing at ${nested_kc}" >&2
    return 1
  fi
  if [[ "${max_attempts}" -lt 1 ]]; then
    max_attempts=1
  fi

  for attempt in $(seq 1 "${max_attempts}"); do
    if KUBECONFIG="${nested_kc}" oc --request-timeout=5s get namespace default &>/dev/null; then
      echo "Guest API reachable via nested kubeconfig (attempt ${attempt}/${max_attempts})"
      return 0
    fi
    echo "Waiting for guest API (attempt ${attempt}/${max_attempts})..."
    sleep 10
  done
  echo "ERROR: guest API not reachable after ${wait_sec}s (check proxy-url on nested kubeconfig)" >&2
  return 1
}

localnet_vlan_configure_guest_cno() {
  echo "Configuring guest CNO: ipForwarding=Global, routingViaHost=true (local gateway mode)..."

  local current_forwarding current_rvh
  current_forwarding=$(localnet_vlan_nested_oc get network.operator cluster \
    -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.ipForwarding}' 2>/dev/null || true)
  current_rvh=$(localnet_vlan_nested_oc get network.operator cluster \
    -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}' 2>/dev/null || true)

  if [[ "${current_forwarding}" == "Global" && "${current_rvh}" == "true" ]]; then
    echo "Guest CNO already configured (ipForwarding=Global, routingViaHost=true)"
    return 0
  fi

  if ! localnet_vlan_nested_oc patch network.operator cluster --type=merge -p \
    '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"ipForwarding":"Global","routingViaHost":true}}}}}'; then
    echo "ERROR: failed to patch guest network.operator" >&2
    return 1
  fi
  echo "Guest CNO patched; waiting for guest OVN rollout..."

  for _ in $(seq 1 60); do
    local ready desired
    if ! ready=$(localnet_vlan_nested_oc get daemonset ovnkube-node -n openshift-ovn-kubernetes \
      -o jsonpath='{.status.updatedNumberScheduled}' 2>/dev/null); then
      echo "WARNING: guest API error while checking ovnkube-node rollout; retrying..." >&2
      sleep 10
      continue
    fi
    if ! desired=$(localnet_vlan_nested_oc get daemonset ovnkube-node -n openshift-ovn-kubernetes \
      -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null); then
      echo "WARNING: guest API error while checking ovnkube-node desired; retrying..." >&2
      sleep 10
      continue
    fi
    if [[ "${ready}" -gt 0 && "${ready}" == "${desired}" ]]; then
      echo "Guest OVN rollout complete (${ready}/${desired} updated)"
      return 0
    fi
    sleep 10
  done
  echo "ERROR: guest OVN rollout not complete after 10 minutes" >&2
  return 1
}

localnet_vlan_label_egress_nodes() {
  local node_names
  node_names=$(localnet_vlan_nested_oc get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  if [[ -z "${node_names}" ]]; then
    echo "ERROR: no guest nodes found for egress-assignable labeling" >&2
    return 1
  fi

  echo "Labeling guest nodes with k8s.ovn.org/egress-assignable..."
  for node in ${node_names}; do
    localnet_vlan_nested_oc label node "${node}" \
      k8s.ovn.org/egress-assignable="" --overwrite
  done
  echo "Guest egress-assignable labeling complete"
}

localnet_vlan_wait_nested_api_ready

localnet_vlan_configure_guest_cno

if [[ "${LOCALNET_VLAN_EGRESS_ENABLE}" == "true" ]]; then
  localnet_vlan_label_egress_nodes
fi

echo "Localnet-vlan guest post-configuration complete"
