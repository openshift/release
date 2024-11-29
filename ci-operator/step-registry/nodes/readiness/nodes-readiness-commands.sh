#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

function debug() {
  echo "[DEBUG] Current machinesets, machines and nodes are:"
  set +e
  for resource in machinesets.machine.openshift.io machines.machine.openshift.io nodes; do
    oc -n openshift-machine-api get "${resource}" -owide | tee "${ARTIFACT_DIR}/${resource}.txt"
    oc -n openshift-machine-api get "${resource}" -oyaml | tee "${ARTIFACT_DIR}/${resource}.yaml"
    oc -n openshift-machine-api describe "${resource}"   | tee "${ARTIFACT_DIR}/${resource}-describe.txt"
  done
  set -e
}

# get_ready_nodes_count returns the number of ready nodes
function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}

# wait_for_nodes_readiness loops until the number of ready nodes objects is equal to the desired one
# It takes 3 arguments:
# - expected_nodes: the number of nodes that should be ready
# - max_retries: the maximum number of retries before failing. Default: 30.
# - period: the time to wait between retries in minutes. Default: 1.
function wait_for_nodes_readiness()
{
  local expected_nodes=${1}
  local max_retries=${2:-30}
  local period=${3:-1}
  echo "[INFO] Waiting for ${expected_nodes} nodes to be ready..."
  for i in $(seq 1 "${max_retries}") max; do
    if [ "${i}" == "max" ]; then
      echo "[ERROR] Timeout reached. ${expected_nodes} ready nodes expected, found ${ready_nodes}... Failing."
      debug
      return 1
    fi
    ready_nodes=$(get_ready_nodes_count)
    if [ "${ready_nodes}" == "${expected_nodes}" ]; then
        echo "[INFO] Found ${ready_nodes}/${expected_nodes} ready nodes, continuing..."
        return 0
    fi
    echo "[INFO] - ${expected_nodes} ready nodes expected, found ${ready_nodes}..." \
      "Waiting ${period}min before retrying (timeout in $(( (max_retries - i + 1) * (period) ))min)..."
    sleep "${period}m"
  done
}

EDGE_ZONES_COUNT=$(yq-v4 -r '.compute[] | select(.name == "edge") | .platform.aws.zones | length // 0' "${SHARED_DIR}/install-config.yaml")
expected_nodes=$(( $(yq-v4 -r '.controlPlane.replicas // '"${CONTROL_PLANE_REPLICAS:-3}" "${SHARED_DIR}/install-config.yaml") +
  $(yq-v4 -r '.compute[] | select(.name == "worker") | .replicas // '"${COMPUTE_NODE_REPLICAS:-3}" "${SHARED_DIR}/install-config.yaml") +
  $(yq-v4 -r '.compute[] | select(.name == "edge") | .replicas // '"${EDGE_ZONES_COUNT}" "${SHARED_DIR}/install-config.yaml")
))

wait_for_nodes_readiness "${expected_nodes}"
echo "[INFO] All nodes are ready."
oc get nodes -owide
