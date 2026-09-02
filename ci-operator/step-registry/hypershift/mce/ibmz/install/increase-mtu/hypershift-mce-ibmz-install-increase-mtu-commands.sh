#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Allow callers to redirect oc commands to a different cluster by setting
# INSTALL_KUBECONFIG. Empty = use ci-operator default (management cluster).
if [[ -n "${INSTALL_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${INSTALL_KUBECONFIG}"
fi

# --- Read current cluster network MTU ---
CURRENT_MTU=$(oc get network.config cluster \
  -o jsonpath='{.status.clusterNetworkMTU}' 2>/dev/null || echo "")

if [[ -z "${CURRENT_MTU}" ]]; then
  echo "$(date) WARNING: could not read current clusterNetworkMTU — defaulting to 1400"
  CURRENT_MTU=1400
fi
echo "$(date) Current cluster network MTU: ${CURRENT_MTU}"
echo "$(date) Target overlay MTU: ${MTU_OVERLAY_TO}, target machine MTU: ${MTU_MACHINE_TO}"

if [[ "${CURRENT_MTU}" == "${MTU_OVERLAY_TO}" ]]; then
  echo "$(date) Cluster network MTU is already ${MTU_OVERLAY_TO} — nothing to do"
  exit 0
fi

# --- Trigger MTU migration ---
# The Machine Config Operator applies the machine MTU first (reboots nodes),
# then the network operator updates the overlay MTU on OVN-Kubernetes.
# For OVN-Kubernetes: overlay MTU must be exactly 100 less than machine MTU.
echo "$(date) Patching Network.operator.openshift.io/cluster to begin MTU migration..."
oc patch Network.operator.openshift.io cluster --type=merge --patch \
  "{\"spec\":{\"migration\":{\"mtu\":{\"network\":{\"from\":${CURRENT_MTU},\"to\":${MTU_OVERLAY_TO}},\"machine\":{\"to\":${MTU_MACHINE_TO}}}}}}"

# --- Wait for MachineConfigPool to finish rolling reboot ---
# MCO reboots nodes one at a time; this can take 20-30 min on a 5-node cluster.
echo "$(date) Waiting for MachineConfigPool worker to finish applying MTU config..."
MCP_TIMEOUT=${MCP_WAIT_TIMEOUT}
MCP_INTERVAL=60
MCP_ELAPSED=0

while [[ ${MCP_ELAPSED} -lt ${MCP_TIMEOUT} ]]; do
  UPDATED=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
  TOTAL=$(oc get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
  DEGRADED=$(oc get mcp worker -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "0")
  UPDATING=$(oc get mcp worker -o jsonpath='{.status.updatingMachineCount}' 2>/dev/null || echo "0")
  echo "$(date) MCP worker: updated=${UPDATED}/${TOTAL}, updating=${UPDATING}, degraded=${DEGRADED} (${MCP_ELAPSED}s elapsed)"
  if [[ "${UPDATED}" == "${TOTAL}" && "${TOTAL}" != "0" && "${DEGRADED}" == "0" && "${UPDATING}" == "0" ]]; then
    echo "$(date) MCP worker is fully updated"
    break
  fi
  sleep ${MCP_INTERVAL}
  MCP_ELAPSED=$((MCP_ELAPSED + MCP_INTERVAL))
done

# Also wait for master MCP
echo "$(date) Waiting for MachineConfigPool master to finish applying MTU config..."
MCP_ELAPSED=0
while [[ ${MCP_ELAPSED} -lt ${MCP_TIMEOUT} ]]; do
  UPDATED=$(oc get mcp master -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
  TOTAL=$(oc get mcp master -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
  DEGRADED=$(oc get mcp master -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "0")
  UPDATING=$(oc get mcp master -o jsonpath='{.status.updatingMachineCount}' 2>/dev/null || echo "0")
  echo "$(date) MCP master: updated=${UPDATED}/${TOTAL}, updating=${UPDATING}, degraded=${DEGRADED} (${MCP_ELAPSED}s elapsed)"
  if [[ "${UPDATED}" == "${TOTAL}" && "${TOTAL}" != "0" && "${DEGRADED}" == "0" && "${UPDATING}" == "0" ]]; then
    echo "$(date) MCP master is fully updated"
    break
  fi
  sleep ${MCP_INTERVAL}
  MCP_ELAPSED=$((MCP_ELAPSED + MCP_INTERVAL))
done

if [[ "${MCP_ELAPSED}" -ge "${MCP_TIMEOUT}" ]]; then
  echo "$(date) ERROR: MachineConfigPool did not finish within ${MCP_TIMEOUT}s"
  oc get mcp || true
  oc get nodes || true
  exit 1
fi

# --- Confirm new MTU ---
NEW_MTU=$(oc get network.config cluster \
  -o jsonpath='{.status.clusterNetworkMTU}' 2>/dev/null || echo "unknown")
echo "$(date) MTU migration complete. Cluster network MTU is now: ${NEW_MTU}"
oc get nodes -o wide || true
