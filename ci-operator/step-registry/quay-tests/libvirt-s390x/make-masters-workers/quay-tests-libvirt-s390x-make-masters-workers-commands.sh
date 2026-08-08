#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Convert a limited number of control-plane nodes into dual-role
# master+worker nodes that are schedulable for workloads.
#
# Default SCHEDULABLE_MASTER_COUNT=2 so we only use two masters as workers
# when the cluster has three control-plane nodes and two dedicated computes.

SCHEDULABLE_MASTER_COUNT="${SCHEDULABLE_MASTER_COUNT:-2}"

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig not found; cluster install may have failed"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Waiting for master nodes to be Ready..."
oc wait node --selector=node-role.kubernetes.io/master --for=condition=Ready --timeout=15m

mapfile -t masters < <(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
master_total="${#masters[@]}"

if [[ "${master_total}" -eq 0 ]]; then
  echo "ERROR: no master nodes found"
  exit 1
fi

if [[ "${SCHEDULABLE_MASTER_COUNT}" -gt "${master_total}" ]]; then
  echo "ERROR: SCHEDULABLE_MASTER_COUNT=${SCHEDULABLE_MASTER_COUNT} exceeds master count ${master_total}"
  exit 1
fi

echo "Found ${master_total} master node(s); converting first ${SCHEDULABLE_MASTER_COUNT} to schedulable workers"

# Enable mastersSchedulable so the scheduler allows workloads on control-plane nodes.
# We then re-taint any masters beyond SCHEDULABLE_MASTER_COUNT so only N stay schedulable.
echo "Patching scheduler cluster mastersSchedulable=true..."
oc patch scheduler cluster --type=merge -p '{"spec":{"mastersSchedulable":true}}'

# Give the operator a moment to reconcile taints
sleep 30

for (( i=0; i<SCHEDULABLE_MASTER_COUNT; i++ )); do
  node="${masters[$i]}"
  echo "Labeling ${node} with worker role and ensuring it is schedulable..."
  oc label node "${node}" node-role.kubernetes.io/worker= --overwrite
  # Remove master NoSchedule taint if still present
  oc adm taint nodes "${node}" node-role.kubernetes.io/master:NoSchedule- || true
done

# Keep remaining masters non-schedulable (dedicated control-plane)
for (( i=SCHEDULABLE_MASTER_COUNT; i<master_total; i++ )); do
  node="${masters[$i]}"
  echo "Keeping ${node} as dedicated master (NoSchedule)..."
  oc adm taint nodes "${node}" node-role.kubernetes.io/master=:NoSchedule --overwrite=true
done

echo "Node roles and taints after conversion:"
oc get nodes -o wide
oc describe nodes | grep -E 'Name:|Roles:|Taints:' || true

echo "Waiting for converted master+worker nodes to be Ready..."
for (( i=0; i<SCHEDULABLE_MASTER_COUNT; i++ )); do
  oc wait node "${masters[$i]}" --for=condition=Ready --timeout=10m
done

echo "Done: ${SCHEDULABLE_MASTER_COUNT} master(s) converted to schedulable workers"
