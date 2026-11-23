#!/usr/bin/env bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# NodePools of unrelated HostedClusters can share ${HYPERSHIFT_NAMESPACE}, so every
# query below is scoped to the HostedCluster under test via .spec.clusterName.
# Waiting on a foreign NodePool, and adding its replicas to the expected node
# count, would mean waiting for nodes that can never join this guest cluster.
cluster_name_file="${SHARED_DIR}/cluster-name"
if [[ ! -f "${cluster_name_file}" ]]; then
    echo "Error: ${cluster_name_file} does not exist." >&2
    echo "The step that creates the HostedCluster is expected to write its name there." >&2
    exit 1
fi
cluster_name="$(<"${cluster_name_file}")"

nodepools=()
while IFS= read -r nodepool; do
    if [[ -n "${nodepool}" ]]; then
        nodepools+=( "${nodepool}" )
    fi
done < <(oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath="{range .items[?(@.spec.clusterName==\"${cluster_name}\")]}{.metadata.name}{\"\n\"}{end}")

# No NodePools at all is itself a condition the caller wants to know about.
if [[ "${#nodepools[@]}" -eq 0 ]]; then
    echo "Error: HostedCluster ${cluster_name} has no NodePools in ${HYPERSHIFT_NAMESPACE}." >&2
    oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" >&2 || true
    exit 1
fi

echo "Waiting for NodePool(s) ${nodepools[*]} of HostedCluster ${cluster_name} to report Ready"
oc wait --timeout="${NODEPOOL_READY_TIMEOUT}" -n "${HYPERSHIFT_NAMESPACE}" \
    --for=condition=Ready=True nodepool "${nodepools[@]}"

# Ready NodePools report how many machines they actually have, which is how many
# guest cluster nodes are expected to join.
expected_nodes="$(oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath="{range .items[?(@.spec.clusterName==\"${cluster_name}\")]}{.status.replicas}{\"\n\"}{end}" |
    awk '{ sum += $1 } END { print sum+0 }')"

if [[ "${expected_nodes}" -lt 1 ]]; then
    echo "Error: NodePools of ${cluster_name} report ${expected_nodes} replicas." >&2
    echo "Refusing to continue, since any per-node check would vacuously pass." >&2
    oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" >&2 || true
    exit 1
fi

echo "Expecting ${expected_nodes} guest cluster node(s) to join"
deadline=$(( SECONDS + NODE_JOIN_TIMEOUT ))
while true; do
    # The guest API server is reachable only once the control plane has finished
    # rolling out, and it can drop connections while nodes are joining. Treat a
    # failed list as "no nodes yet" and retry until the deadline, rather than
    # letting set -e/pipefail end the step on a transient error.
    if ! node_list="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers 2>&1)"; then
        echo "$(date --rfc-3339=seconds) could not list guest cluster nodes: ${node_list}"
        node_list=""
    fi

    # Column 2 is STATUS, which is "Ready" or e.g. "Ready,SchedulingDisabled".
    ready_nodes="$(awk '$2 ~ /^Ready/ { count++ } END { print count+0 }' <<<"${node_list}")"

    if [[ "${ready_nodes}" -ge "${expected_nodes}" ]]; then
        echo "All ${expected_nodes} expected guest cluster node(s) have joined and are Ready"
        break
    fi

    if (( SECONDS >= deadline )); then
        echo "Error: timed out waiting for guest cluster nodes to join." >&2
        echo "Expected ${expected_nodes} Ready node(s), found ${ready_nodes}." >&2
        oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes >&2 || true
        exit 1
    fi

    echo "$(date --rfc-3339=seconds) ${ready_nodes}/${expected_nodes} node(s) Ready, waiting..."
    sleep 30
done

oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes
