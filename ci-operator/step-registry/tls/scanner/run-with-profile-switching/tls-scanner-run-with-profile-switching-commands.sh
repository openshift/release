#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# TLS Scanner with Profile Switching - tests dynamic TLS profile changes
# This script:
# 1. Scans endpoints with the initial profile (Intermediate/default)
# 2. Switches to Modern profile
# 3. Verifies operators reload and re-scans
# 4. Switches to Old profile
# 5. Verifies operators reload and re-scans
# 6. Restores to Intermediate profile

NAMESPACE="tls-scanner"
SCANNER_IMAGE="${PULL_SPEC_TLS_SCANNER_TOOL}"
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}"
SCANNER_ARTIFACT_DIR="${ARTIFACT_DIR}/tls-scanner-profile-switching"

# Determine scanner arguments based on whether a specific namespace is requested
if [[ -n "${SCAN_NAMESPACE:-}" ]]; then
    SCANNER_ARGS="--all-pods --namespace-filter ${SCAN_NAMESPACE}"
else
    SCANNER_ARGS="--all-pods"
fi

mkdir -p "${SCANNER_ARTIFACT_DIR}"

echo "=== TLS Scanner with Profile Switching ==="
echo "Scanner Image: ${SCANNER_IMAGE}"
echo "Scanner Args: ${SCANNER_ARGS}"

# Create namespace
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Cleanup on exit
cleanup() {
    echo "Cleaning up..."
    oc delete namespace "${NAMESPACE}" --ignore-not-found --wait=false || true
}
trap cleanup EXIT

# Grant cluster-admin to the default service account for full access
oc adm policy add-cluster-role-to-user cluster-admin -z default -n "${NAMESPACE}"

# Grant privileged SCC to the service account (required for hostNetwork, hostPID, privileged container)
oc adm policy add-scc-to-user privileged -z default -n "${NAMESPACE}"

# Wait for RBAC/SCC changes to propagate
echo "Waiting for RBAC/SCC changes to propagate..."
sleep 10

# Function to run TLS scanner
run_scanner() {
    local profile_name=$1
    local output_prefix=$2

    echo "=== Running TLS Scanner for profile: ${profile_name} ==="

    # Create the scanner pod
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tls-scanner-${output_prefix}
  namespace: ${NAMESPACE}
spec:
  serviceAccountName: default
  restartPolicy: Never
  hostNetwork: true
  hostPID: true
  containers:
  - name: scanner
    image: ${SCANNER_IMAGE}
    command:
    - /bin/sh
    - -c
    - |
      mkdir -p /results
      /usr/local/bin/tls-scanner ${SCANNER_ARGS} \
        --json-file /results/results.json \
        --csv-file /results/results.csv \
        --junit-file /results/junit_tls_scan_${output_prefix}.xml \
        --log-file /results/scan.log 2>&1 | tee /results/output.log
      echo "Scan complete. Exit code: \$?"
      # Keep pod alive for artifact collection
      sleep 120
    securityContext:
      privileged: true
      runAsUser: 0
    volumeMounts:
    - name: results
      mountPath: /results
  volumes:
  - name: results
    emptyDir: {}
EOF

    echo "Waiting for scanner pod to start..."
    oc wait --for=condition=Ready pod/tls-scanner-${output_prefix} -n "${NAMESPACE}" --timeout=5m || {
        echo "Pod failed to start:"
        oc describe pod/tls-scanner-${output_prefix} -n "${NAMESPACE}"
        oc get events -n "${NAMESPACE}"
        return 1
    }

    echo "Waiting for scan to complete..."
    # Poll logs until scan completes
    local max_wait=600  # 10 minutes
    local elapsed=0
    while true; do
        if oc logs pod/tls-scanner-${output_prefix} -n "${NAMESPACE}" 2>/dev/null | grep -q "Scan complete"; then
            break
        fi
        if [ $elapsed -ge $max_wait ]; then
            echo "ERROR: Scan did not complete within ${max_wait} seconds"
            oc logs pod/tls-scanner-${output_prefix} -n "${NAMESPACE}" || true
            return 1
        fi
        echo "  Scan still running... (${elapsed}s elapsed)"
        sleep 30
        elapsed=$((elapsed + 30))
    done

    echo "Scan completed. Fetching full logs..."
    oc logs pod/tls-scanner-${output_prefix} -n "${NAMESPACE}" > "${SCANNER_ARTIFACT_DIR}/scan-${output_prefix}.log" || true

    echo "Copying artifacts..."
    local profile_dir="${SCANNER_ARTIFACT_DIR}/${output_prefix}"
    mkdir -p "${profile_dir}"
    oc cp "${NAMESPACE}/tls-scanner-${output_prefix}:/results/." "${profile_dir}/" || echo "Warning: Failed to copy some artifacts"

    # Copy JUnit XML to root artifact dir for Spyglass
    if [[ -f "${profile_dir}/junit_tls_scan_${output_prefix}.xml" ]]; then
        cp "${profile_dir}/junit_tls_scan_${output_prefix}.xml" "${ARTIFACT_DIR}/junit_tls_scan_${output_prefix}.xml"
        echo "JUnit results copied to ${ARTIFACT_DIR}/junit_tls_scan_${output_prefix}.xml"
    fi

    # Wait for pod to complete
    oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/tls-scanner-${output_prefix} -n "${NAMESPACE}" --timeout=4h || {
        echo "Scanner did not complete successfully"
        oc describe pod/tls-scanner-${output_prefix} -n "${NAMESPACE}"
        return 1
    }

    # Delete the pod to free resources
    oc delete pod tls-scanner-${output_prefix} -n "${NAMESPACE}" --wait=false || true

    echo "=== Scanner run complete for ${profile_name} ==="
}

# Function to switch TLS profile
switch_profile() {
    local profile_type=$1
    local profile_field=$2

    echo "=== Switching to ${profile_type} TLS Profile ==="

    oc patch apiserver cluster --type=merge -p "{\"spec\":{\"tlsSecurityProfile\":{\"type\":\"${profile_type}\",\"${profile_field}\":{}}}}"

    # Verify the change
    local current_profile=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.type}')
    if [[ "$current_profile" != "$profile_type" ]]; then
        echo "ERROR: Failed to switch to ${profile_type}. Current profile: ${current_profile}"
        return 1
    fi
    echo "Successfully switched to ${profile_type} profile"

    # Wait for operators to reload configuration
    echo "Waiting for operators to reload configuration (90 seconds)..."
    sleep 90

    # Wait for cluster to stabilize
    echo "Waiting for cluster to stabilize..."
    oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=10m || {
        echo "WARNING: Cluster did not stabilize within timeout, but continuing..."
    }

    # Check for degraded operators
    local degraded_operators=$(oc get co -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Degraded" and .status=="True")) | .metadata.name' || echo "")
    if [[ -n "$degraded_operators" ]]; then
        echo "WARNING: Some operators are degraded after switching to ${profile_type}:"
        echo "$degraded_operators"
        oc get co
    else
        echo "All operators are healthy after switching to ${profile_type}"
    fi
}

# Main test flow

# Step 1: Record initial profile
echo "=== Step 1: Recording initial TLS profile ==="
initial_profile=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile.type}' || echo "")
if [[ -z "$initial_profile" || "$initial_profile" == "null" ]]; then
    initial_profile="Intermediate (default)"
fi
echo "Initial TLS profile: ${initial_profile}" | tee "${SCANNER_ARTIFACT_DIR}/initial-profile.txt"

# Wait for cluster to be stable before starting
echo "Ensuring cluster is stable before starting..."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=5m || {
    echo "WARNING: Cluster not fully stable, but continuing..."
}

# Step 2: Scan with initial profile (Intermediate/default)
echo "=== Step 2: Scanning with initial profile ==="
run_scanner "Intermediate" "intermediate" || {
    echo "ERROR: Initial scan failed"
    exit 1
}

# Step 3: Switch to Modern and scan
switch_profile "Modern" "modern" || {
    echo "ERROR: Failed to switch to Modern profile"
    exit 1
}
run_scanner "Modern" "modern" || {
    echo "ERROR: Modern profile scan failed"
    exit 1
}

# Step 4: Switch to Old and scan
switch_profile "Old" "old" || {
    echo "ERROR: Failed to switch to Old profile"
    exit 1
}
run_scanner "Old" "old" || {
    echo "ERROR: Old profile scan failed"
    exit 1
}

# Step 5: Restore to Intermediate
echo "=== Step 5: Restoring to Intermediate profile ==="
switch_profile "Intermediate" "intermediate" || {
    echo "WARNING: Failed to restore to Intermediate profile"
}

# Step 6: Final scan with Intermediate
run_scanner "Intermediate-Final" "intermediate-final" || {
    echo "ERROR: Final Intermediate scan failed"
    exit 1
}

# Generate summary report
echo "=== Generating Summary Report ==="
cat > "${SCANNER_ARTIFACT_DIR}/summary.txt" <<EOF
TLS Profile Switching Test Summary
===================================

Initial Profile: ${initial_profile}

Test Sequence:
1. Intermediate (initial) - Scan completed
2. Modern - Scan completed
3. Old - Scan completed
4. Intermediate (restored) - Scan completed

All scans completed successfully!

Artifacts located in: ${SCANNER_ARTIFACT_DIR}
- intermediate/: Initial scan results
- modern/: Modern profile scan results
- old/: Old profile scan results
- intermediate-final/: Final scan results after restoration

JUnit XML files copied to ${ARTIFACT_DIR} for CI reporting.
EOF

cat "${SCANNER_ARTIFACT_DIR}/summary.txt"

echo "=== TLS Profile Switching Test Complete ==="
echo "All artifacts saved to: ${SCANNER_ARTIFACT_DIR}"
ls -la "${SCANNER_ARTIFACT_DIR}" || true
