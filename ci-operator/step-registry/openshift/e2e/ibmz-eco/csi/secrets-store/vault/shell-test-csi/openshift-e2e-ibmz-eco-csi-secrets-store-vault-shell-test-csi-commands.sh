#!/bin/bash

# set -e causes the script to fail immediately if any command returns a non-zero exit code
# set -x prints commands for debugging in Prow logs
set -e
set -x

echo "$(date) [INFO] Starting s390x connectivity test in Prow..."

# Variables
TEST_NS="vault" # Using 'vault' to match your original script's target
POD_NAME="s390x-connectivity-check-$(date +%s)"
IMAGE="registry.access.redhat.com/ubi8/ubi-minimal:latest" # Safe for Prow, native s390x support

# Ensure the namespace exists (create if missing to prevent CI failure)
if ! oc get project "$TEST_NS" >/dev/null 2>&1; then
    echo "$(date) [WARN] Namespace '$TEST_NS' missing. Creating it for test..."
    oc new-project "$TEST_NS" || oc create namespace "$TEST_NS"
fi

# Cleanup trap: Ensures the pod is deleted even if the script fails or is cancelled
cleanup() {
    echo "$(date) [INFO] Cleaning up test pod..."
    oc delete pod "$POD_NAME" -n "$TEST_NS" --ignore-not-found --wait=false
}
trap cleanup EXIT

# 1. Run the Pod
# using 'ubi-minimal' because it's whitelisted in most Red Hat environments
echo "$(date) [INFO] Spawning pod $POD_NAME on s390x..."
oc run "$POD_NAME" \
    --image="$IMAGE" \
    --namespace="$TEST_NS" \
    --restart=Never \
    --overrides='{"spec": {"nodeSelector": {"kubernetes.io/arch": "s390x"}}}' \
    -- echo "s390x-alive"

# 2. Wait for completion (Timeout set to 60s to fail fast)
echo "$(date) [INFO] Waiting for pod to succeed..."
if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$POD_NAME" -n "$TEST_NS" --timeout=60s; then
    echo "$(date) [ERROR] Pod failed to complete within timeout!"
    
    # CRITICAL FOR PROW DEBUGGING:
    # Get logs and events to see if it was an ImagePullBackOff or Scheduling issue
    echo "--- POD LOGS ---"
    oc logs "$POD_NAME" -n "$TEST_NS" || echo "No logs found."
    echo "--- POD EVENTS ---"
    oc describe pod "$POD_NAME" -n "$TEST_NS"
    
    exit 1
fi

# 3. Verify Output
LOGS=$(oc logs "$POD_NAME" -n "$TEST_NS")
if [[ "$LOGS" == *"s390x-alive"* ]]; then
    echo "$(date) [SUCCESS] s390x test passed. Pod ran and printed: $LOGS"
else
    echo "$(date) [FAILURE] Pod finished, but output was unexpected: $LOGS"
    exit 1
fi