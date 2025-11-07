#!/bin/bash
# More robust error handling
set -euo pipefail

# Source system-wide profiles to ensure Go and Rust commands are in our PATH.
# This is necessary because this script runs in a new shell session, separate
# from the provisioning step that installed them.
if [ -f "/etc/profile.d/go.sh" ]; then
    source "/etc/profile.d/go.sh"
fi
if [ -f "/etc/profile.d/rust.sh" ]; then
    source "/etc/profile.d/rust.sh"
fi

# This script assumes the host has been prepared and a KinD cluster is running.

# ============================================================================
# Clone operator Repository and Apply Patch
# ============================================================================
echo "[INFO] Cloning trusted-execution-clusters operator repository..."

# Use environment variables from the CI job, with sensible defaults
COCL_OPERATOR_REPO="${COCL_OPERATOR_REPO:-https://github.com/trusted-execution-clusters/operator.git}"
COCL_OPERATOR_BRANCH="${COCL_OPERATOR_BRANCH:-main}"
COCL_OPERATOR_PATCH_URL="https://patch-diff.githubusercontent.com/raw/trusted-execution-clusters/operator/pull/98.patch"

WORK_DIR="${HOME}/trusted-execution-clusters"
rm -rf "${WORK_DIR}"

# Clone the repository using the specified branch
echo "[INFO] Cloning branch '${COCL_OPERATOR_BRANCH}' from '${COCL_OPERATOR_REPO}'"
git clone --branch "${COCL_OPERATOR_BRANCH}" "${COCL_OPERATOR_REPO}" "${WORK_DIR}"
cd "${WORK_DIR}"

echo "[INFO] Applying patch from ${COCL_OPERATOR_PATCH_URL}"
curl -L "${COCL_OPERATOR_PATCH_URL}" | git apply

echo "[SUCCESS] Repository is ready."

# ============================================================================
# Deploy Operator
# ============================================================================

# --- Set the container runtime ---
CONTAINER_RUNTIME="docker"

# --- Set up the environment ---
# The IP 192.168.122.1 is the default for the libvirt network on the host.
export IP="192.168.122.1"
export RUNTIME="${CONTAINER_RUNTIME}"
export CONTAINER_CLI="${CONTAINER_RUNTIME}"
echo "[INFO] Run make cluster-up"
make cluster-up RUNTIME="${RUNTIME}"

echo "[INFO] Building and pushing container images to the local registry..."

# --- Build and push the container images ---
make REGISTRY=localhost:5000 push BUILD_TYPE=debug RUNTIME="${RUNTIME}"

echo "[INFO] Generating manifests..."
make REGISTRY=localhost:5000 manifests RUNTIME="${RUNTIME}"

echo "[INFO] Installing the operator..."
make TRUSTEE_ADDR="${IP}" install RUNTIME="${RUNTIME}"

echo "[SUCCESS] cocl-operator installation complete."


# ============================================================================
# Verify Cluster and CoCl Health
# ============================================================================

echo "[INFO] Verifying Kubernetes Cluster Node Status"
echo "$ kubectl get nodes -o wide"
if ! kubectl get nodes -o wide; then
    echo "[ERROR] Failed to get node status. Please check your kubectl configuration and cluster."
    exit 1
fi
echo "[INFO] Nodes are running"

echo ""

echo "[INFO] Verifying Pod Status in 'trusted-execution-clusters' Namespace"
echo "$ kubectl get pods -n trusted-execution-clusters -o wide"
if ! kubectl get pods -n trusted-execution-clusters -o wide; then
    echo "[ERROR] Failed to get pods from the 'trusted-execution-clusters' namespace."
    exit 1
fi

echo ""

echo "[INFO] Waiting for pods in 'trusted-execution-clusters' namespace to be running"
TIMEOUT=900
SECONDS=0
while [ $SECONDS -lt $TIMEOUT ]; do
    echo ""
    echo "[INFO] Checking pod status (elapsed: ${SECONDS}s / ${TIMEOUT}s)"

    # Check for pods that have failed completely
    echo "$ kubectl get pods --field-selector=status.phase=Failed -n trusted-execution-clusters -o jsonpath='{.items[*].metadata.name}'"
    FAILED_PHASE_PODS=$(kubectl get pods --field-selector=status.phase=Failed -n trusted-execution-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -n "$FAILED_PHASE_PODS" ]; then
        echo "[ERROR] The following pods have failed:"
        for pod in $FAILED_PHASE_PODS;
        do
            echo "[INFO] - $pod"
            echo "$ kubectl describe pod \"$pod\" -n trusted-execution-clusters"
            kubectl describe pod "$pod" -n trusted-execution-clusters
        done
        echo "[INFO] Current status of all resources in 'trusted-execution-clusters' namespace"
        echo "$ kubectl get all -n trusted-execution-clusters"
        kubectl get all -n trusted-execution-clusters
        exit 1
    fi

    # Check for pods with container errors that prevent them from starting
    echo "$ kubectl get pods -n trusted-execution-clusters -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' | grep -E \"CrashLoopBackOff|ImagePullBackOff|CreateContainerError|ErrImagePull|CreateContainerConfigError|InvalidImageName\" | awk '{print \$1}' || true"
    ERROR_REASON_PODS=$(kubectl get pods -n trusted-execution-clusters -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.containerStatuses[*]}{.state.waiting.reason}{" "}{end}{"\n"}{end}' | grep -E "CrashLoopBackOff|ImagePullBackOff|CreateContainerError|ErrImagePull|CreateContainerConfigError|InvalidImageName" | awk '{print $1}' || true)
    if [ -n "$ERROR_REASON_PODS" ]; then
        echo "[ERROR] The following pods have container errors:"
        for pod in $ERROR_REASON_PODS;
        do
            echo "[INFO] - $pod"
        done
        echo "[INFO] Current status of all resources in 'trusted-execution-clusters' namespace"
        echo "$ kubectl get all -n trusted-execution-clusters"
        kubectl get all -n trusted-execution-clusters
        exit 1
    fi

    # Get current pod status for display
    echo "$ kubectl get pods -n trusted-execution-clusters -o wide"
    kubectl get pods -n trusted-execution-clusters -o wide

    # Check if all pods are running or have succeeded
    echo "$ kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n trusted-execution-clusters -o jsonpath='{.items[*].metadata.name}'"
    NOT_RUNNING_PODS=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n trusted-execution-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -z "$NOT_RUNNING_PODS" ]; then
        echo "[INFO] All pods are running."
        echo "[INFO] Final status of all resources in 'trusted-execution-clusters' namespace"
        echo "$ kubectl get all -n trusted-execution-clusters"
        kubectl get all -n trusted-execution-clusters
        break
    fi

    echo "[INFO] Still waiting for pods to be ready: $NOT_RUNNING_PODS"
    sleep 10
    SECONDS=$((SECONDS + 10))
done

if [ $SECONDS -ge $TIMEOUT ]; then
    echo "[ERROR] Timeout waiting for pods to be ready."
    echo "[INFO] Current status of all resources in 'trusted-execution-clusters' namespace"
    kubectl get all -n trusted-execution-clusters
    FAILED_PODS=$(kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded -n trusted-execution-clusters -o jsonpath='{.items[*].metadata.name}')
    if [ -n "$FAILED_PODS" ]; then
        echo "[ERROR] The following pods are not in a 'Running' or 'Succeeded' state:"
        for pod in $FAILED_PODS;
        do
            echo "[INFO] - $pod"
            echo "$ kubectl describe pod \"$pod\" -n trusted-execution-clusters"
            kubectl describe pod "$pod" -n trusted-execution-clusters
            echo "[INFO] End of description for pod: $pod"
        done
    fi
    exit 1
fi
