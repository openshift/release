#!/usr/bin/env bash

set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Waiting for every NodePool in namespace ${HYPERSHIFT_NAMESPACE} to report Ready"
# Fails with "no matching resources found" if the HostedCluster has no NodePools
# at all, which is itself a condition the caller wants to know about.
oc wait --timeout="${NODEPOOL_READY_TIMEOUT}" nodepool -n "${HYPERSHIFT_NAMESPACE}" --all --for=condition=Ready=True

# Ready NodePools report how many machines they actually have, which is how many
# guest cluster nodes are expected to join.
expected_nodes="$(oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.status.replicas}{"\n"}{end}' |
    awk '{ sum += $1 } END { print sum+0 }')"

if [[ "${expected_nodes}" -lt 1 ]]; then
    echo "Error: NodePools in ${HYPERSHIFT_NAMESPACE} report ${expected_nodes} replicas." >&2
    echo "Refusing to continue, since any per-node check would vacuously pass." >&2
    oc get nodepool -n "${HYPERSHIFT_NAMESPACE}" >&2 || true
    exit 1
fi

echo "Expecting ${expected_nodes} guest cluster node(s) to join"
deadline=$(( SECONDS + NODE_JOIN_TIMEOUT ))
while true; do
    # Column 2 is STATUS, which is "Ready" or e.g. "Ready,SchedulingDisabled".
    ready_nodes="$(oc --kubeconfig "${SHARED_DIR}/nested_kubeconfig" get nodes --no-headers 2>/dev/null |
        awk '$2 ~ /^Ready/ { count++ } END { print count+0 }')"

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
