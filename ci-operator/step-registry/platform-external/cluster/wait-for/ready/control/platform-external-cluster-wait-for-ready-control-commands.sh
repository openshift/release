#!/bin/bash

#
# Platform agnostic check waiting for control plane nodes stayed in Ready phase.
#

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/init-fn.sh" || true

# Configuration
MAX_ITERATIONS=${CONTROL_PLANE_WAIT_MAX_ITERATIONS:-60}  # 60 iterations * 30s = 30 minutes
ITERATION=0
DIAGNOSTIC_INTERVAL=5  # Collect diagnostics every 5 iterations (2.5 minutes)

# Helper function: Collect diagnostic snapshot
function collect_diagnostic_snapshot() {
  local iteration=$1
  local diagnostic_dir="${ARTIFACT_DIR}/control-plane-diagnostics/iteration-$(printf "%03d" $iteration)"
  mkdir -p "${diagnostic_dir}"

  log "Collecting diagnostic snapshot to ${diagnostic_dir}"

  # Node status
  oc get nodes -o wide > "${diagnostic_dir}/nodes.txt" 2>&1 || true
  oc get nodes -o yaml > "${diagnostic_dir}/nodes.yaml" 2>&1 || true

  # Master node details
  oc get nodes -l node-role.kubernetes.io/master -o yaml > "${diagnostic_dir}/master-nodes.yaml" 2>&1 || true
  oc describe nodes -l node-role.kubernetes.io/master > "${diagnostic_dir}/master-nodes-describe.txt" 2>&1 || true

  # Pod status in critical namespaces
  for ns in kube-system openshift-kube-apiserver openshift-etcd openshift-machine-api; do
    oc get pods -n ${ns} -o wide > "${diagnostic_dir}/pods-${ns}.txt" 2>&1 || true
  done

  # Events
  oc get events -A --sort-by='.lastTimestamp' | tail -50 > "${diagnostic_dir}/events-recent.txt" 2>&1 || true

  # Machine API (if available)
  oc get machines -n openshift-machine-api -o yaml > "${diagnostic_dir}/machines.yaml" 2>&1 || true
  oc get machinesets -n openshift-machine-api -o yaml > "${diagnostic_dir}/machinesets.yaml" 2>&1 || true

  # Cluster operators status
  oc get clusteroperators > "${diagnostic_dir}/clusteroperators.txt" 2>&1 || true
}

# Helper function: Collect final diagnostics on failure
function collect_final_diagnostics() {
  local final_dir="${ARTIFACT_DIR}/control-plane-final-state"
  mkdir -p "${final_dir}"

  log "Collecting final diagnostics to ${final_dir}"

  oc get nodes -o wide > "${final_dir}/nodes.txt" 2>&1 || true
  oc get nodes -o yaml > "${final_dir}/nodes.yaml" 2>&1 || true
  oc describe nodes > "${final_dir}/nodes-describe.txt" 2>&1 || true

  # Pod status across all namespaces
  oc get pods -A -o wide > "${final_dir}/pods-all.txt" 2>&1 || true

  # Critical namespace details
  for ns in kube-system openshift-kube-apiserver openshift-etcd openshift-machine-api openshift-cloud-controller-manager; do
    mkdir -p "${final_dir}/namespace-${ns}"
    oc get all -n ${ns} -o yaml > "${final_dir}/namespace-${ns}/resources.yaml" 2>&1 || true
    oc describe pods -n ${ns} > "${final_dir}/namespace-${ns}/pods-describe.txt" 2>&1 || true
    oc get events -n ${ns} --sort-by='.lastTimestamp' > "${final_dir}/namespace-${ns}/events.txt" 2>&1 || true
  done

  # Cluster state
  oc get clusteroperators -o yaml > "${final_dir}/clusteroperators.yaml" 2>&1 || true
  oc get clusterversion -o yaml > "${final_dir}/clusterversion.yaml" 2>&1 || true

  # Machine API
  oc get machines,machinesets -n openshift-machine-api -o yaml > "${final_dir}/machines.yaml" 2>&1 || true

  # Create summary
  cat > "${final_dir}/summary.txt" << EOF
Control Plane Wait Timeout Summary
===================================
Date: $(date -u --rfc-3339=seconds)
Iterations: ${ITERATION}/${MAX_ITERATIONS}
Duration: ~$((ITERATION * 30 / 60)) minutes

Node Status:
$(oc get nodes 2>&1 || echo "Unable to get nodes")

Master Nodes:
$(oc get nodes -l node-role.kubernetes.io/master 2>&1 || echo "Unable to get master nodes")

Critical Pods Status:
$(oc get pods -n kube-system 2>&1 || echo "Unable to get kube-system pods")
$(oc get pods -n openshift-kube-apiserver 2>&1 || echo "Unable to get apiserver pods")
$(oc get pods -n openshift-etcd 2>&1 || echo "Unable to get etcd pods")

Recent Events:
$(oc get events -A --sort-by='.lastTimestamp' | tail -20 2>&1 || echo "Unable to get events")
EOF

  log "Final diagnostics summary:"
  cat "${final_dir}/summary.txt"
}

function wait_for_masters() {
  log "Waiting for control plane nodes to become ready (max ${MAX_ITERATIONS} iterations, ~30 minutes)"
  set +e

  while [ $ITERATION -lt $MAX_ITERATIONS ]; do
    ITERATION=$((ITERATION + 1))

    # Try to wait for masters with short timeout
    if oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s 2>/dev/null; then
      log "SUCCESS: All master nodes are ready!"
      oc get nodes -l node-role.kubernetes.io/master
      return 0
    fi

    # Check current state
    MASTER_COUNT=$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l || echo "0")
    READY_COUNT=$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers 2>/dev/null | grep " Ready " | wc -l || echo "0")

    log "[${ITERATION}/${MAX_ITERATIONS}] Masters: ${READY_COUNT}/${MASTER_COUNT} ready"

    # Show current status
    oc get nodes -l node-role.kubernetes.io/master 2>&1 || log "Unable to get master nodes"

    # If we have 3 masters and they're all ready, we're done
    if [[ "${MASTER_COUNT}" -eq 3 ]] && [[ "${READY_COUNT}" -eq 3 ]]; then
      log "Found 3 ready master nodes, exiting..."
      return 0
    fi

    # Collect diagnostics periodically
    if [ $((ITERATION % DIAGNOSTIC_INTERVAL)) -eq 0 ]; then
      collect_diagnostic_snapshot "${ITERATION}"
    fi

    # Show progress markers every 5 minutes
    if [ $((ITERATION % 10)) -eq 0 ]; then
      log "[$(((ITERATION * 30) / 60)) minutes] Still waiting for masters..."
      log "Current pod status in kube-system:"
      oc get pods -n kube-system 2>&1 | head -10 || true
    fi

    sleep 30
  done

  # Timeout reached
  log "ERROR: Timeout waiting for control plane nodes after ${MAX_ITERATIONS} iterations (~$((MAX_ITERATIONS * 30 / 60)) minutes)"
  collect_final_diagnostics
  return 1
}

log "=> Waiting for Control Plane nodes"

if ! wait_for_masters; then
  log "ERROR: Failed to wait for control plane nodes"
  exit 1
fi

log "Control plane nodes are ready!"
oc get nodes
