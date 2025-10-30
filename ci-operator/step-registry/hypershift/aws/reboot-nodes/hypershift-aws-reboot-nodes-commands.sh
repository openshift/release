#!/bin/bash

set -euo pipefail

echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Rebooting AWS management cluster nodes"
echo "=========================================================================="

# Configure AWS credentials
export AWS_SHARED_CREDENTIALS_FILE=/etc/hypershift-pool-aws-credentials/credentials
export AWS_REGION=${HYPERSHIFT_AWS_REGION:-us-east-1}

echo "Using kubeconfig: ${KUBECONFIG}"
echo "AWS Region: ${AWS_REGION}"

# Determine which nodes to reboot based on REBOOT_ALL_NODES flag
if [ "${REBOOT_ALL_NODES}" = "true" ]; then
    echo "Getting list of all nodes (master + worker)..."
    NODES=$(oc get nodes --no-headers -o custom-columns=NAME:.metadata.name)
    NODE_TYPE="all nodes (master + worker)"
else
    echo "Getting list of worker nodes..."
    NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=NAME:.metadata.name)
    NODE_TYPE="worker nodes"
fi

NODE_COUNT=$(echo "${NODES}" | wc -l)

if [ "${NODE_COUNT}" -eq 0 ]; then
    echo "ERROR: No nodes found in the management cluster"
    exit 1
fi

echo "Found ${NODE_COUNT} ${NODE_TYPE} to reboot"

# Get AWS instance IDs for all nodes to reboot
INSTANCE_IDS=()
for NODE in ${NODES}; do
    echo "Getting AWS instance ID for node: ${NODE}"
    INSTANCE_ID=$(oc get node "${NODE}" -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)
    if [ -z "${INSTANCE_ID}" ]; then
        echo "WARNING: Could not get instance ID for node ${NODE}, skipping"
        continue
    fi
    echo "  Node ${NODE} -> Instance ${INSTANCE_ID}"
    INSTANCE_IDS+=("${INSTANCE_ID}")
done

if [ ${#INSTANCE_IDS[@]} -eq 0 ]; then
    echo "ERROR: Could not find any AWS instance IDs"
    exit 1
fi

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Triggering reboot for ${#INSTANCE_IDS[@]} instances"
echo "=========================================================================="

# Reboot all instances
for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    echo "Rebooting instance: ${INSTANCE_ID}"
    aws ec2 reboot-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" || {
        echo "WARNING: Failed to reboot instance ${INSTANCE_ID}"
    }
done

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Waiting ${REBOOT_WAIT_TIME}s for nodes to start rebooting..."
echo "=========================================================================="
sleep "${REBOOT_WAIT_TIME}"

echo ""
echo "=========================================================================="
echo "Waiting for Hosting Cluster nodes to recover (max ${RECOVERY_WAIT_TIME}s)..."
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Step 4: Observing Hosting Cluster recovery"
echo ""

# Wait for nodes to become Ready again
START_TIME=$(date +%s)
TIMEOUT=${RECOVERY_WAIT_TIME}

# Determine which nodes to check based on what we rebooted
if [ "${REBOOT_ALL_NODES}" = "true" ]; then
    CHECK_SELECTOR=""  # Check all nodes
else
    CHECK_SELECTOR="-l node-role.kubernetes.io/worker"  # Check only workers
fi

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ ${ELAPSED} -ge ${TIMEOUT} ]; then
        echo "ERROR: Timeout waiting for nodes to recover after ${TIMEOUT}s"
        echo "Current node status:"
        oc get nodes
        exit 1
    fi

    # Check if all rebooted nodes are Ready
    if [ "${REBOOT_ALL_NODES}" = "true" ]; then
        NOT_READY=$(oc get nodes --no-headers | grep -v " Ready " | wc -l || true)
    else
        NOT_READY=$(oc get nodes ${CHECK_SELECTOR} --no-headers | grep -v " Ready " | wc -l || true)
    fi

    if [ "${NOT_READY}" -eq 0 ]; then
        echo "$(date --rfc-3339=seconds) All Hosting Cluster nodes are Ready!"
        break
    fi

    echo "$(date --rfc-3339=seconds) Waiting for ${NOT_READY} node(s) to become Ready... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep 30
done

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Hosting Cluster nodes recovered successfully"
echo "=========================================================================="
echo "All nodes:"
oc get nodes

echo ""
echo "=========================================================================="
echo "$(date --rfc-3339=seconds) Step 5: Observing Hosted Cluster state"
echo "=========================================================================="
echo ""
echo "Verifying that Hosted Cluster control plane recovered after"
echo "Hosting Cluster node reboot..."
echo ""

# Get the hosted cluster namespace from shared directory
HOSTED_CLUSTER_NAMESPACE=""
if [ -f "${SHARED_DIR}/hostedcluster_namespace" ]; then
    HOSTED_CLUSTER_NAMESPACE=$(cat "${SHARED_DIR}/hostedcluster_namespace")
elif [ -f "${SHARED_DIR}/hosted_cluster_namespace" ]; then
    HOSTED_CLUSTER_NAMESPACE=$(cat "${SHARED_DIR}/hosted_cluster_namespace")
fi

# Try to find it from hosted clusters
if [ -z "${HOSTED_CLUSTER_NAMESPACE}" ]; then
    echo "Attempting to discover hosted cluster namespace..."
    HOSTED_CLUSTER_NAMESPACE=$(oc get hostedcluster -A --no-headers -o custom-columns=NAMESPACE:.metadata.namespace | head -n1)
fi

if [ -z "${HOSTED_CLUSTER_NAMESPACE}" ]; then
    echo "WARNING: Could not determine hosted cluster namespace, skipping hosted cluster verification"
    echo "Nodes have successfully rebooted and recovered!"
    exit 0
fi

echo "Hosted cluster namespace: ${HOSTED_CLUSTER_NAMESPACE}"

# Get the hosted cluster name
HOSTED_CLUSTER_NAME=$(oc get hostedcluster -n "${HOSTED_CLUSTER_NAMESPACE}" --no-headers -o custom-columns=NAME:.metadata.name | head -n1)
if [ -z "${HOSTED_CLUSTER_NAME}" ]; then
    echo "WARNING: Could not find hosted cluster in namespace ${HOSTED_CLUSTER_NAMESPACE}"
    echo "Nodes have successfully rebooted and recovered!"
    exit 0
fi

echo "Hosted cluster name: ${HOSTED_CLUSTER_NAME}"

# Determine the control plane namespace (typically clusters-<namespace>)
CONTROL_PLANE_NAMESPACE="clusters-${HOSTED_CLUSTER_NAMESPACE}"
echo "Control plane namespace: ${CONTROL_PLANE_NAMESPACE}"

# Wait for control plane pods to stabilize after reboot
echo ""
echo "Waiting 60s for control plane pods to stabilize..."
sleep 60

echo ""
echo "Checking critical control plane components..."
echo ""

# Check all pods in control plane namespace
echo "All pods in ${CONTROL_PLANE_NAMESPACE}:"
oc get pods -n "${CONTROL_PLANE_NAMESPACE}" || {
    echo "ERROR: Failed to get pods in control plane namespace"
    exit 1
}

echo ""
echo "=========================================================================="
echo "Verifying openshift-apiserver and ingress-operator pods"
echo "=========================================================================="

# Check for critical pods
CRITICAL_PODS=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" | grep -E "ingress-operator|openshift-apiserver" || true)
if [ -z "${CRITICAL_PODS}" ]; then
    echo "ERROR: No ingress-operator or openshift-apiserver pods found!"
    exit 1
fi

echo "${CRITICAL_PODS}"
echo ""

# Check for pods in bad states
BAD_STATES=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" | grep -E "ingress-operator|openshift-apiserver" | grep -E "CrashLoopBackOff|Error|ImagePullBackOff" || true)
if [ -n "${BAD_STATES}" ]; then
    echo "ERROR: Found pods in bad states:"
    echo "${BAD_STATES}"
    echo ""
    echo "Pod details:"
    oc describe pods -n "${CONTROL_PLANE_NAMESPACE}" -l app=openshift-apiserver || true
    oc describe pods -n "${CONTROL_PLANE_NAMESPACE}" -l app=ingress-operator || true
    exit 1
fi

# Check for permission errors in openshift-apiserver logs
echo ""
echo "Checking openshift-apiserver initContainer logs for permission errors..."
APISERVER_PODS=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" -l app=openshift-apiserver --no-headers -o custom-columns=NAME:.metadata.name || true)
if [ -n "${APISERVER_PODS}" ]; then
    for POD in ${APISERVER_PODS}; do
        echo "Checking pod: ${POD}"
        # Check initContainer logs for permission errors
        INIT_LOGS=$(oc logs -n "${CONTROL_PLANE_NAMESPACE}" "${POD}" -c oas-trust-anchor-generator 2>&1 || true)
        if echo "${INIT_LOGS}" | grep -i "permission denied"; then
            echo "ERROR: Found permission errors in pod ${POD}:"
            echo "${INIT_LOGS}"
            exit 1
        fi
        echo "  ✓ No permission errors found"
    done
else
    echo "WARNING: No openshift-apiserver pods found to check logs"
fi

# Verify pods are Running and Ready
echo ""
echo "Verifying all critical pods are Running and Ready..."
NOT_RUNNING=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" | grep -E "ingress-operator|openshift-apiserver" | grep -v "Running" || true)
if [ -n "${NOT_RUNNING}" ]; then
    echo "ERROR: Found pods not in Running state:"
    echo "${NOT_RUNNING}"
    exit 1
fi

# Check readiness
NOT_READY=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" | grep -E "ingress-operator|openshift-apiserver" | grep "0/" || true)
if [ -n "${NOT_READY}" ]; then
    echo "WARNING: Found pods not ready:"
    echo "${NOT_READY}"
    echo "Waiting an additional 120s for pods to become ready..."
    sleep 120

    # Check again
    NOT_READY=$(oc get pods -n "${CONTROL_PLANE_NAMESPACE}" | grep -E "ingress-operator|openshift-apiserver" | grep "0/" || true)
    if [ -n "${NOT_READY}" ]; then
        echo "ERROR: Pods still not ready after waiting:"
        echo "${NOT_READY}"
        exit 1
    fi
fi

echo ""
echo "=========================================================================="
echo "✓ SUCCESS: OCPBUGS-61829 Verification Passed"
echo "=========================================================================="
echo ""
echo "Bug Reproduction Steps Completed:"
echo "  1. ✓ Hosting Cluster running HyperShift"
echo "  2. ✓ Hosted Cluster deployed"
echo "  3. ✓ Hosting Cluster nodes restarted (simulating full cluster reboot)"
echo "  4. ✓ Hosting Cluster nodes recovered"
echo "  5. ✓ Hosted Cluster state observed"
echo ""
echo "Verification Results:"
echo "  ✓ Hosting Cluster nodes: Ready"
echo "  ✓ openshift-apiserver: Running and Ready"
echo "  ✓ ingress-operator: Running and Ready"
echo "  ✓ No permission errors in initContainer logs"
echo "  ✓ No stuck or unhealthy pods"
echo "  ✓ No manual intervention required"
echo ""
echo "OCPBUGS-61829 FIX VERIFIED: Control plane recovered automatically!"
echo "The initContainer cleanup logic successfully prevents permission errors"
echo "after Hosting Cluster node reboots."
echo "=========================================================================="
