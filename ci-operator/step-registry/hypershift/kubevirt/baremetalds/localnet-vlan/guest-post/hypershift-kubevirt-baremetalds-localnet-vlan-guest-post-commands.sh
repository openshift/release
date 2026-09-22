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

  local num_ready desired updated
  for _ in $(seq 1 60); do
    if ! num_ready=$(localnet_vlan_nested_oc get daemonset ovnkube-node -n openshift-ovn-kubernetes \
      -o jsonpath='{.status.numberReady}' 2>/dev/null); then
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
    updated=$(localnet_vlan_nested_oc get daemonset ovnkube-node -n openshift-ovn-kubernetes \
      -o jsonpath='{.status.updatedNumberScheduled}' 2>/dev/null || echo "0")
    if [[ "${num_ready}" -gt 0 && "${num_ready}" == "${desired}" && "${updated}" == "${desired}" ]]; then
      echo "Guest OVN rollout complete (${num_ready}/${desired} ready, ${updated} updated)"
      break
    fi
    echo "  ovnkube-node: ${num_ready}/${desired} ready, ${updated} updated..."
    sleep 10
  done

  if [[ "${num_ready:-0}" -lt 1 || "${num_ready:-0}" != "${desired:-1}" ]]; then
    echo "ERROR: guest OVN rollout not complete after 10 minutes" >&2
    return 1
  fi

  echo "Waiting for guest network ClusterOperator to stabilize..."
  local co_available co_progressing co_degraded
  for _ in $(seq 1 30); do
    co_available=$(localnet_vlan_nested_oc get co network \
      -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    co_progressing=$(localnet_vlan_nested_oc get co network \
      -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}' 2>/dev/null || true)
    co_degraded=$(localnet_vlan_nested_oc get co network \
      -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || true)
    if [[ "${co_available}" == "True" && "${co_progressing}" == "False" && "${co_degraded}" != "True" ]]; then
      echo "Guest network CO stable: Available=True, Progressing=False, Degraded=${co_degraded:-False}"
      return 0
    fi
    echo "  network CO: Available=${co_available:-?}, Progressing=${co_progressing:-?}, Degraded=${co_degraded:-?}"
    sleep 10
  done
  echo "WARNING: guest network CO not fully stable after 5 minutes (continuing)" >&2
  return 0
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
