#!/bin/bash
set -euo pipefail

# OVS Timeout Fix Validation for OCPBUGS-66075
# Tests the 90-second OVS timeout fix under high concurrent pod creation load

echo "Starting OVS Timeout Fix Validation for OCPBUGS-66075"
echo "Testing OVS timeout increase from 30s to 90s in HyperShift HCP environment"
echo "Using custom release: registry.build07.ci.openshift.org/ci-ln-l477g5k/release:latest"
echo "Target pods: ${OVS_TIMEOUT_TEST_PODS:-1000}"

# Function to log with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OCPBUGS-66075] $*"
}

log "Creating test deployment with ${OVS_TIMEOUT_TEST_PODS:-1000} pods..."

# Create the stress test deployment
cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ovs-timeout-test-deployment
  namespace: ${TEST_NAMESPACE:-default}
  labels:
    app: ovs-timeout-test
    test-id: "OCPBUGS-66075"
    test-purpose: "ovs-timeout-validation"
  annotations:
    test.openshift.io/description: "OVS timeout fix validation for OCPBUGS-66075"
    test.openshift.io/expected-timeout: "90s"
    test.openshift.io/custom-release: "registry.build07.ci.openshift.org/ci-ln-l477g5k/release:latest"
spec:
  replicas: ${OVS_TIMEOUT_TEST_PODS:-1000}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 500
      maxUnavailable: 0
  selector:
    matchLabels:
      app: ovs-timeout-test
  template:
    metadata:
      labels:
        app: ovs-timeout-test
        test-phase: "concurrent-pod-creation"
    spec:
      terminationGracePeriodSeconds: 5
      containers:
      - name: test-container
        image: registry.access.redhat.com/ubi8/ubi-minimal:latest
        command:
        - /bin/bash
        - -c
        - |
          echo "Pod \${HOSTNAME} started at \$(date)"
          echo "Testing OVS timeout fix for OCPBUGS-66075"
          echo "Expected OVS timeout: 90 seconds (was 30 seconds)"
          while true; do
            echo "Pod \${HOSTNAME} alive at \$(date)"
            sleep 600
          done
        resources:
          requests:
            memory: "32Mi"
            cpu: "5m"
          limits:
            memory: "64Mi"
            cpu: "10m"
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: NODE_NAME
          valueFrom:
            fieldRef:
              fieldPath: spec.nodeName
      restartPolicy: Always
EOF

log "Monitoring pod creation progress..."

start_time=$(date +%s)
max_pods_ready=0
timeout_errors=0
target_pods=${OVS_TIMEOUT_TEST_PODS:-1000}
max_wait=${OVS_TIMEOUT_MAX_WAIT:-2400}

# Monitor for up to MAX_WAIT seconds
while true; do
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  
  if [ $elapsed -gt $max_wait ]; then
    log "ERROR: Test timed out after $max_wait seconds"
    break
  fi
  
  # Get pod statistics
  running_pods=$(oc get pods -l app=ovs-timeout-test --no-headers 2>/dev/null | grep "Running" | wc -l || echo 0)
  pending_pods=$(oc get pods -l app=ovs-timeout-test --no-headers 2>/dev/null | grep -E "Pending|ContainerCreating" | wc -l || echo 0)
  failed_pods=$(oc get pods -l app=ovs-timeout-test --no-headers 2>/dev/null | grep -vE "Running|Pending|ContainerCreating" | wc -l || echo 0)
  
  # Track maximum pods reached
  if [ $running_pods -gt $max_pods_ready ]; then
    max_pods_ready=$running_pods
  fi
  
  # Check for OVS timeout errors
  new_timeout_errors=$(oc get events --field-selector reason=FailedCreatePodSandBox -o json 2>/dev/null | \
    jq -r '[.items[] | select(.message | test("timeout.*ovs|ovs.*timeout|timeout.*30|timeout.*90", "i"))] | length' 2>/dev/null || echo 0)
  timeout_errors=$new_timeout_errors
  
  log "Progress: ${running_pods}/${target_pods} Running, ${pending_pods} Pending, ${failed_pods} Failed | Time: ${elapsed}s | Timeout Errors: ${timeout_errors}"
  
  # Success condition
  if [ $running_pods -eq $target_pods ]; then
    log "SUCCESS: All ${target_pods} pods are running!"
    break
  fi
  
  # Check for high failure rate
  if [ $failed_pods -gt $((target_pods / 4)) ]; then
    log "ERROR: High failure rate detected: ${failed_pods} failed pods"
    break
  fi
  
  sleep 15
done

# Final results and cleanup
end_time=$(date +%s)
total_elapsed=$((end_time - start_time))

log "=== FINAL TEST RESULTS ==="
log "Custom Release: registry.build07.ci.openshift.org/ci-ln-l477g5k/release:latest"
log "Target pods: ${target_pods}"
log "Maximum pods running: ${max_pods_ready}"
log "Final running pods: ${running_pods}"
log "Failed pods: ${failed_pods}"
log "Total elapsed time: ${total_elapsed} seconds"
log "OVS timeout errors: ${timeout_errors}"

# Collect debug info
echo "=== Recent Events ==="
oc get events --sort-by='.lastTimestamp' | tail -30

echo "=== Node Resources ==="
oc adm top nodes || echo "Node metrics not available"

# Cleanup
log "Cleaning up test deployment..."
oc delete deployment ovs-timeout-test-deployment --ignore-not-found=true --timeout=120s

# Determine test result
success_threshold=$((target_pods * 85 / 100))  # 85% success rate

if [ $timeout_errors -eq 0 ] && [ $max_pods_ready -ge $success_threshold ]; then
  log "🎉 TEST RESULT: PASSED ✅"
  log "✅ Zero OVS timeout errors - 90s timeout fix is working"
  log "✅ Successfully created ${max_pods_ready} concurrent pods (≥${success_threshold} required)"
  exit 0
else
  log "💥 TEST RESULT: FAILED ❌"
  if [ $timeout_errors -gt 0 ]; then
    log "❌ Found ${timeout_errors} OVS timeout errors"
  fi
  if [ $max_pods_ready -lt $success_threshold ]; then
    log "❌ Only reached ${max_pods_ready} pods (required ≥${success_threshold})"
  fi
  exit 1
fi