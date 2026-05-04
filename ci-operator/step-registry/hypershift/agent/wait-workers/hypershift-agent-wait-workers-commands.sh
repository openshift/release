#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Wait for Workers to Join HyperShift Hosted Cluster ************"

# Get hosted cluster information
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
HOSTED_CLUSTER_NAME=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.name}')
HOSTED_CONTROL_PLANE_NAMESPACE="${HOSTED_CLUSTER_NS}-${HOSTED_CLUSTER_NAME}"
NUM_WORKERS="${NUM_EXTRA_WORKERS:-2}"

echo "$(date -u --rfc-3339=seconds) - Hosted cluster: ${HOSTED_CLUSTER_NAME}"
echo "$(date -u --rfc-3339=seconds) - Control plane namespace: ${HOSTED_CONTROL_PLANE_NAMESPACE}"
echo "$(date -u --rfc-3339=seconds) - Expected workers: ${NUM_WORKERS}"

# Wait for Agent CRs to be created (VMs booting from ISO)
echo "$(date -u --rfc-3339=seconds) - Waiting for Agent resources to be created..."
_agentExist=0
set +e
for ((i=1; i<=30; i++)); do
    count=$(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers --ignore-not-found | wc -l)
    if [ ${count} -ge ${NUM_WORKERS} ]; then
        echo "$(date -u --rfc-3339=seconds) - Found ${count} agent resources (expected: ${NUM_WORKERS})"
        _agentExist=1
        break
    fi
    echo "$(date -u --rfc-3339=seconds) - Waiting for agents... (${count}/${NUM_WORKERS}) attempt ${i}/30"
    sleep 30
done
set -e

if [ $_agentExist -eq 0 ]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Expected ${NUM_WORKERS} agents, found ${count}"
    oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} || true
    exit 1
fi

# List all agents
echo "$(date -u --rfc-3339=seconds) - Agent resources:"
oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE}

# Approve all Agents
echo "$(date -u --rfc-3339=seconds) - Approving agents..."
for item in $(oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} --no-headers | awk '{print $1}'); do
    oc patch agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} ${item} \
        -p '{"spec":{"approved":true}}' --type merge
    echo "$(date -u --rfc-3339=seconds) - Approved agent: ${item}"
done

# Scale NodePool to match worker count
echo "$(date -u --rfc-3339=seconds) - Scaling NodePool to ${NUM_WORKERS} replicas..."
oc scale nodepool ${HOSTED_CLUSTER_NAME} \
    -n ${HOSTED_CLUSTER_NS} \
    --replicas ${NUM_WORKERS}

# Wait for all Agents to join the cluster
echo "$(date -u --rfc-3339=seconds) - Waiting for agents to join the hosted cluster..."
echo "$(date -u --rfc-3339=seconds) - This may take 20-40 minutes (downloading ignition, installing to disk, rebooting)"

oc wait --all=true agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE} \
    --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster \
    --timeout=40m

echo "$(date -u --rfc-3339=seconds) - All agents successfully joined the cluster!"

# Display final agent status
echo "$(date -u --rfc-3339=seconds) - Final agent status:"
oc get agent -n ${HOSTED_CONTROL_PLANE_NAMESPACE}

# Verify nodes in the hosted cluster
echo "$(date -u --rfc-3339=seconds) - Verifying nodes in hosted cluster..."
export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
oc get nodes

echo "$(date -u --rfc-3339=seconds) - Successfully added ${NUM_WORKERS} worker nodes to the hosted cluster!"
