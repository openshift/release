#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# KUBECONFIG already points at the management cluster: ci-operator exports
# ${SHARED_DIR}/kubeconfig for every step, and nothing here repoints it at the
# guest. The hosted control plane workloads live in the management cluster's
# hosted control plane namespace.

MCE=${MCE_VERSION:-""}
CLUSTER_NAME="$(echo -n "${PROW_JOB_ID}" | sha256sum | cut -c-20)"
if [[ -n ${MCE} ]]; then
  CLUSTER_NAMESPACE_PREFIX=local-cluster
else
  CLUSTER_NAMESPACE_PREFIX=clusters
fi
CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE_PREFIX}-${CLUSTER_NAME}

# Node identity is never printed. What this step needs to report is counts and
# scheduler reasons, and the scheduler counts nodes rather than naming them, so
# nothing diagnostic is lost. scrub is a backstop for any message that does
# carry a name or address.
scrub() {
  sed -E -e 's/ip-([0-9]+-){3}[0-9]+\.[a-z0-9.-]*internal/<node>/g' \
         -e 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/<ip>/g'
}

# zone_histogram answers the question that matters on a failure -- is every
# node in one zone? -- without identifying any node.
zone_histogram() {
  oc get nodes -o go-template='{{range .items}}{{index .metadata.labels "topology.kubernetes.io/zone"}}{{"\n"}}{{end}}' \
    | awk 'NF' | sort | uniq -c | awk '{printf "  %s node(s) in zone %s\n", $1, $2}'
}

verify_spread() {
  local deployment="$1"
  local selector="$2"
  local replicas
  local live_nodes
  local pod_count
  local nodes
  local node_count
  local replica_index
  local zone

  if ! replicas=$(oc get deployment "${deployment}" -n "${CLUSTER_NAMESPACE}" -o jsonpath='{.spec.replicas}'); then
    echo "ERROR: failed to get Deployment ${deployment} in ${CLUSTER_NAMESPACE}" >&2
    return 1
  fi

  echo "${deployment} in ${CLUSTER_NAMESPACE} has ${replicas} replica(s)"
  if [[ "${replicas}" -le 1 ]]; then
    echo "CNO renders the anti-affinity only above one replica, so there is nothing to verify here."
    echo "Set CONTROL_PLANE_AVAILABILITY=HighlyAvailable for this check to mean anything."
    return 0
  fi

  # A required zone anti-affinity cannot be satisfied when every management
  # node carries the same topology.kubernetes.io/zone value, so on a
  # single-zone cluster the second replica stays Pending and this times out.
  if ! oc rollout status "deployment/${deployment}" -n "${CLUSTER_NAMESPACE}" --timeout="${NETWORK_CP_ROLLOUT_TIMEOUT}"; then
    echo "ERROR: ${deployment} did not roll out within ${NETWORK_CP_ROLLOUT_TIMEOUT}"
    echo "An unsatisfiable anti-affinity appears below as a Pending pod whose scheduler"
    echo "reason reads \"didn't match pod anti-affinity rules\"."
    oc get pods -n "${CLUSTER_NAMESPACE}" -l "${selector}" \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers || true
    # Only FailedScheduling: the rest of the event stream records node
    # assignments, while this reason is expressed as "N of M nodes".
    oc get events -n "${CLUSTER_NAMESPACE}" --field-selector reason=FailedScheduling \
      -o custom-columns=POD:.involvedObject.name,REASON:.message --no-headers 2>/dev/null | scrub || true
    zone_histogram || true
    return 1
  fi

  # Relaxing the zone rule must not let the replicas share a node: the
  # required hostname rule is what still guarantees node-level spreading.
  #
  # A terminating pod keeps reporting status.phase=Running, and counting it
  # would hide the very thing being checked: two new replicas on one node plus
  # an old pod draining on another still looks like two distinct nodes. Drop
  # anything carrying a deletion timestamp, then require one live pod per node.
  live_nodes=$(oc get pods -n "${CLUSTER_NAMESPACE}" -l "${selector}" \
    --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.spec.nodeName}}{{"\n"}}{{end}}{{end}}')
  pod_count=$(echo "${live_nodes}" | awk 'NF' | wc -l)
  nodes=$(echo "${live_nodes}" | awk 'NF' | sort -u)
  node_count=$(echo "${nodes}" | awk 'NF' | wc -l)

  if [[ "${pod_count}" -ne "${replicas}" ]] || [[ "${node_count}" -ne "${pod_count}" ]]; then
    echo "ERROR: expected ${replicas} ${deployment} replicas on ${replicas} distinct nodes,"
    echo "found ${pod_count} running non-terminating pod(s) on ${node_count} node(s);"
    echo "the required hostname anti-affinity is not holding."
    oc get pods -n "${CLUSTER_NAMESPACE}" -l "${selector}" \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase --no-headers || true
    # How the replicas are bunched, without identifying the nodes they bunched on.
    echo "${live_nodes}" | awk 'NF' | sort | uniq -c \
      | awk '{printf "  %s replica(s) on one node\n", $1}'
    zone_histogram || true
    return 1
  fi

  # Zones are reported, not asserted: on a single-zone management cluster
  # every replica shares a zone and that is the expected outcome.
  replica_index=0
  while read -r node; do
    replica_index=$((replica_index + 1))
    zone=$(oc get node "${node}" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')
    echo "  replica ${replica_index} in zone ${zone:-<unlabelled>}"
  done <<< "${nodes}"

  echo "${deployment}: ${replicas} replicas on ${node_count} distinct node(s)"
}

workloads=(
  "ovnkube-control-plane app=ovnkube-control-plane"
  "network-node-identity-v2 app=network-node-identity-v2"
  "multus-admission-controller app=multus-admission-controller"
)

for workload in "${workloads[@]}"; do
  read -r deployment selector <<< "${workload}"
  verify_spread "${deployment}" "${selector}"
done
