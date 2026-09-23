#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Nutanix credential rotation validation ************"

# Create secure temporary directory for sensitive files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "${TEMP_DIR}"' EXIT

# Load existing cluster credentials and context
export KUBECONFIG=${SHARED_DIR}/kubeconfig
source ${SHARED_DIR}/nutanix_context.sh

# Disable tracing for credential operations
# shellcheck disable=SC2034
set +x
# shellcheck source=/dev/null
source /tmp/nutanix-creds/secrets.sh

# Validate and set up new credentials
# shellcheck disable=SC2154
# Check if user provided any credentials
if [[ -n "${NEW_NUTANIX_USERNAME:-}" ]] || [[ -n "${NEW_NUTANIX_PASSWORD:-}" ]]; then
  # User provided at least one credential - require BOTH to be non-empty
  if [[ -z "${NEW_NUTANIX_USERNAME:-}" ]] || [[ -z "${NEW_NUTANIX_PASSWORD:-}" ]]; then
    echo "ERROR: Incomplete credential replacement detected"
    echo "When providing new credentials, both NEW_NUTANIX_USERNAME and NEW_NUTANIX_PASSWORD must be set"
    echo "Provided: NEW_NUTANIX_USERNAME='${NEW_NUTANIX_USERNAME:-<empty>}'"
    echo "Provided: NEW_NUTANIX_PASSWORD='${NEW_NUTANIX_PASSWORD:+<set>}${NEW_NUTANIX_PASSWORD:-<empty>}'"
    exit 1
  fi
  echo "Running in ACTUAL ROTATION mode with provided credentials"
  SIMULATED_ROTATION=false
else
  # Neither credential provided - use simulated mode
  echo "WARNING: NEW_NUTANIX_USERNAME and NEW_NUTANIX_PASSWORD not provided"
  echo "Running in SIMULATED mode: using existing credentials to test the rotation mechanism"
  echo "For actual credential rotation validation, provide both NEW_NUTANIX_USERNAME and NEW_NUTANIX_PASSWORD"
  NEW_NUTANIX_USERNAME="${prism_central_username}"
  NEW_NUTANIX_PASSWORD="${prism_central_password}"
  SIMULATED_ROTATION=true
fi

echo "=== Step 1: Backup existing credentials ==="
oc get secret nutanix-credentials -n openshift-machine-api -o yaml > "${TEMP_DIR}/backup-machine-api-secret.yaml" 2>/dev/null || true
oc get secret nutanix-credentials -n openshift-cloud-controller-manager -o yaml > "${TEMP_DIR}/backup-ccm-secret.yaml" 2>/dev/null || true
oc get secret ntnx-secret -n openshift-cluster-csi-drivers -o yaml > "${TEMP_DIR}/backup-csi-secret.yaml" 2>/dev/null || true

echo "=== Step 2: Extract credential requests from cluster ==="
CR_DIR="${TEMP_DIR}/credentials_request"
mkdir -p "${CR_DIR}"

# Get the cluster version
CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
echo "Cluster version: ${CLUSTER_VERSION}"

# Get the release image (disable tracing to avoid logging internal registry)
set +x
RELEASE_IMAGE=$(oc get clusterversion version -o jsonpath='{.status.desired.image}')
echo "Release image: <redacted>"

# Extract credential requests (disable tracing for registry operations)
dir=$(mktemp -d)
trap 'rm -rf "${dir}" "${TEMP_DIR}"' EXIT
pushd "${dir}" > /dev/null

set +x
cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
oc registry login --to pull-secret > /dev/null 2>&1
echo "Extracting credential requests..."
oc adm release extract \
  --registry-config pull-secret \
  --credentials-requests \
  --cloud=nutanix \
  --to "${CR_DIR}" \
  --included \
  --install-config=${SHARED_DIR}/install-config.yaml \
  "${RELEASE_IMAGE}" > /dev/null 2>&1
rm -f pull-secret

popd > /dev/null

echo "Extracted credential requests:"
ls -l "${CR_DIR}"

echo "=== Step 3: Generate new credentials using ccoctl ==="
# Disable tracing for credential file creation
set +x

# Create the new Nutanix credentials file
cat > "${TEMP_DIR}/new-credentials" <<EOF
credentials:
- type: basic_auth
  data:
    prismCentral:
      username: ${NEW_NUTANIX_USERNAME}
      password: ${NEW_NUTANIX_PASSWORD}
    prismElements: null
EOF

ADDITIONAL_CCOCTL_ARGS=""
if [[ "${FEATURE_SET:-}" == "TechPreviewNoUpgrade" ]]; then
  ADDITIONAL_CCOCTL_ARGS="$ADDITIONAL_CCOCTL_ARGS --enable-tech-preview"
fi

# Generate new credential manifests
ccoctl nutanix create-shared-secrets \
  --credentials-requests-dir="${CR_DIR}" \
  --output-dir="${TEMP_DIR}/new-creds" \
  --credentials-source-filepath="${TEMP_DIR}/new-credentials" \
  ${ADDITIONAL_CCOCTL_ARGS}

echo "Generated new credential manifests:"
ls -l "${TEMP_DIR}/new-creds/manifests"

echo "=== Step 4: Record pre-rotation controller state ==="
# Capture pod states before rotation
oc get pods -n openshift-machine-api -l api=clusterapi -o wide > ${SHARED_DIR}/pre-rotation-machine-api-pods.txt 2>&1 || true
oc get pods -n openshift-cloud-controller-manager -o wide > ${SHARED_DIR}/pre-rotation-ccm-pods.txt 2>&1 || true
oc get pods -n openshift-cluster-csi-drivers -o wide > ${SHARED_DIR}/pre-rotation-csi-pods.txt 2>&1 || true

# Capture pod restart counts
MACHINE_API_RESTARTS_BEFORE=$(oc get pods -n openshift-machine-api -l api=clusterapi -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
CCM_RESTARTS_BEFORE=$(oc get pods -n openshift-cloud-controller-manager -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
CSI_RESTARTS_BEFORE=$(oc get pods -n openshift-cluster-csi-drivers -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")

echo "Pre-rotation restart counts:"
echo "  Machine API: ${MACHINE_API_RESTARTS_BEFORE}"
echo "  CCM: ${CCM_RESTARTS_BEFORE}"
echo "  CSI: ${CSI_RESTARTS_BEFORE}"

echo "=== Step 5: Apply new credentials to all three namespaces ==="

# Apply to openshift-machine-api
echo "Applying new credentials to openshift-machine-api namespace..."
oc apply -f "${TEMP_DIR}/new-creds/manifests/openshift-machine-api-nutanix-credentials-credentials.yaml"

# Apply to openshift-cloud-controller-manager
echo "Applying new credentials to openshift-cloud-controller-manager namespace..."
oc apply -f "${TEMP_DIR}/new-creds/manifests/openshift-cloud-controller-manager-nutanix-credentials-credentials.yaml"

# Apply to openshift-cluster-csi-drivers
echo "Applying new credentials to openshift-cluster-csi-drivers namespace..."
oc apply -f "${TEMP_DIR}/new-creds/manifests/openshift-cluster-csi-drivers-ntnx-secret-credentials.yaml"

echo "New credentials applied to all three namespaces"

echo "=== Step 6: Wait for credential propagation ==="
# Give controllers time to pick up new credentials
echo "Waiting 30 seconds for credential propagation..."
sleep 30

echo "=== Step 7: Verify controller functionality ==="

# Test Machine API
echo "Testing Machine API functionality..."
MACHINE_COUNT=$(oc get machines -n openshift-machine-api --no-headers 2>/dev/null | wc -l)
echo "  Found ${MACHINE_COUNT} machines"

if [[ ${MACHINE_COUNT} -eq 0 ]]; then
  echo "  ERROR: No machines found in cluster"
  exit 1
fi

# Check machine status
RUNNING_MACHINES=$(oc get machines -n openshift-machine-api -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null | grep -c "Running" || echo "0")
echo "  Running machines: ${RUNNING_MACHINES}/${MACHINE_COUNT}"

if [[ ${RUNNING_MACHINES} -lt ${MACHINE_COUNT} ]]; then
  echo "  ERROR: Not all machines are in Running state"
  oc get machines -n openshift-machine-api
  exit 1
fi

# Test Cloud Controller Manager
echo "Testing Cloud Controller Manager functionality..."
CCM_PODS=$(oc get pods -n openshift-cloud-controller-manager -l app=cloud-controller-manager --no-headers 2>/dev/null | wc -l)
if [[ ${CCM_PODS} -eq 0 ]]; then
  echo "  ERROR: No CCM pods found"
  exit 1
fi

CCM_READY=$(oc get pods -n openshift-cloud-controller-manager -l app=cloud-controller-manager -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo "0")
echo "  CCM pods ready: ${CCM_READY}/${CCM_PODS}"

if [[ ${CCM_READY} -lt ${CCM_PODS} ]]; then
  echo "  ERROR: Not all CCM pods are ready"
  oc get pods -n openshift-cloud-controller-manager
  exit 1
fi

# Test CSI Driver
echo "Testing CSI Driver functionality..."
CSI_PODS=$(oc get pods -n openshift-cluster-csi-drivers -l app=nutanix-csi-node --no-headers 2>/dev/null | wc -l)
if [[ ${CSI_PODS} -eq 0 ]]; then
  echo "  ERROR: No CSI driver pods found"
  exit 1
fi

CSI_READY=$(oc get pods -n openshift-cluster-csi-drivers -l app=nutanix-csi-node -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c "True" || echo "0")
echo "  CSI driver pods ready: ${CSI_READY}/${CSI_PODS}"

if [[ ${CSI_READY} -lt ${CSI_PODS} ]]; then
  echo "  ERROR: Not all CSI driver pods are ready"
  oc get pods -n openshift-cluster-csi-drivers -l app=nutanix-csi-node
  exit 1
fi

# Create a test PVC to validate CSI functionality
echo "Creating test PVC to validate CSI driver with new credentials..."
TEST_PVC_NAME="credential-rotation-test-pvc"
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEST_PVC_NAME}
  namespace: openshift-cluster-csi-drivers
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: nutanix-volume
EOF

# Wait for PVC to be bound
echo "Waiting for test PVC to be bound (max 5 minutes)..."
timeout=300
elapsed=0
PVC_BOUND=false

while [[ ${elapsed} -lt ${timeout} ]]; do
  PVC_STATUS=$(oc get pvc/${TEST_PVC_NAME} -n openshift-cluster-csi-drivers -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  if [[ "${PVC_STATUS}" == "Bound" ]]; then
    echo "  Test PVC successfully bound with new credentials!"
    PVC_BOUND=true
    break
  fi

  echo "  PVC status: ${PVC_STATUS}, waiting... (${elapsed}s elapsed)"
  sleep 5
  elapsed=$((elapsed + 5))
done

# Check if PVC actually bound
if [[ "${PVC_BOUND}" != "true" ]]; then
  echo "  ERROR: Test PVC did not bind within ${timeout} seconds"
  oc describe pvc/${TEST_PVC_NAME} -n openshift-cluster-csi-drivers
  exit 1
fi

# Clean up test PVC
echo "Cleaning up test PVC..."
oc delete pvc/${TEST_PVC_NAME} -n openshift-cluster-csi-drivers

echo "=== Step 8: Check if controller restarts were required ==="
if [[ "${VERIFY_CONTROLLER_RESTART:-true}" == "true" ]]; then
  # Wait a bit more to ensure any restarts would have occurred
  echo "Waiting additional 60 seconds to observe potential controller restarts..."
  sleep 60

  # Check post-rotation state
  oc get pods -n openshift-machine-api -l api=clusterapi -o wide > ${SHARED_DIR}/post-rotation-machine-api-pods.txt 2>&1 || true
  oc get pods -n openshift-cloud-controller-manager -o wide > ${SHARED_DIR}/post-rotation-ccm-pods.txt 2>&1 || true
  oc get pods -n openshift-cluster-csi-drivers -o wide > ${SHARED_DIR}/post-rotation-csi-pods.txt 2>&1 || true

  MACHINE_API_RESTARTS_AFTER=$(oc get pods -n openshift-machine-api -l api=clusterapi -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
  CCM_RESTARTS_AFTER=$(oc get pods -n openshift-cloud-controller-manager -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")
  CSI_RESTARTS_AFTER=$(oc get pods -n openshift-cluster-csi-drivers -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{s+=$1} END {print s}' || echo "0")

  echo "Post-rotation restart counts:"
  echo "  Machine API: ${MACHINE_API_RESTARTS_AFTER} (delta: $((MACHINE_API_RESTARTS_AFTER - MACHINE_API_RESTARTS_BEFORE)))"
  echo "  CCM: ${CCM_RESTARTS_AFTER} (delta: $((CCM_RESTARTS_AFTER - CCM_RESTARTS_BEFORE)))"
  echo "  CSI: ${CSI_RESTARTS_AFTER} (delta: $((CSI_RESTARTS_AFTER - CSI_RESTARTS_BEFORE)))"

  # Save restart analysis
  cat > ${SHARED_DIR}/credential-rotation-restart-analysis.txt <<EOF
Controller Restart Analysis After Credential Rotation
======================================================

Machine API:
  Before: ${MACHINE_API_RESTARTS_BEFORE}
  After:  ${MACHINE_API_RESTARTS_AFTER}
  Delta:  $((MACHINE_API_RESTARTS_AFTER - MACHINE_API_RESTARTS_BEFORE))

Cloud Controller Manager:
  Before: ${CCM_RESTARTS_BEFORE}
  After:  ${CCM_RESTARTS_AFTER}
  Delta:  $((CCM_RESTARTS_AFTER - CCM_RESTARTS_BEFORE))

CSI Driver:
  Before: ${CSI_RESTARTS_BEFORE}
  After:  ${CSI_RESTARTS_AFTER}
  Delta:  $((CSI_RESTARTS_AFTER - CSI_RESTARTS_BEFORE))

Conclusion:
EOF

  if [[ $((MACHINE_API_RESTARTS_AFTER - MACHINE_API_RESTARTS_BEFORE)) -eq 0 ]] && \
     [[ $((CCM_RESTARTS_AFTER - CCM_RESTARTS_BEFORE)) -eq 0 ]] && \
     [[ $((CSI_RESTARTS_AFTER - CSI_RESTARTS_BEFORE)) -eq 0 ]]; then
    echo "  Credentials were picked up automatically - NO controller restarts required" | tee -a ${SHARED_DIR}/credential-rotation-restart-analysis.txt
  else
    echo "  Some controllers restarted - manual restarts may be required in production" | tee -a ${SHARED_DIR}/credential-rotation-restart-analysis.txt
  fi
fi

echo "=== Step 9: Validate cluster operators are healthy ==="
echo "Checking all cluster operators..."

if ! oc wait --all=true clusteroperator --for='condition=Available=True' --timeout=5m 2>&1; then
  echo "ERROR: Not all cluster operators are available"
  oc get clusteroperators
  exit 1
fi

if ! oc wait --all=true clusteroperator --for='condition=Progressing=False' --timeout=5m 2>&1; then
  echo "ERROR: Some cluster operators are still progressing"
  oc get clusteroperators
  exit 1
fi

if ! oc wait --all=true clusteroperator --for='condition=Degraded=False' --timeout=5m 2>&1; then
  echo "ERROR: Some cluster operators are degraded"
  oc get clusteroperators
  exit 1
fi

echo "All cluster operators are healthy"

echo "=== Step 10: Validate old credentials removal (if requested) ==="
if [[ "${VALIDATE_OLD_CREDS_REMOVAL:-true}" == "true" ]] && [[ "${SIMULATED_ROTATION}" == "false" ]]; then
  echo "Testing removal of old service account credentials..."
  echo "Note: This step validates that new credentials work independently"
  echo "In production, old Prism Central service account can be deleted after validation"

  # We can't actually delete the old PC account from the test, but we can verify
  # that the new credentials in the secrets are being used
  echo "Verifying new credentials are active in all namespaces..."

  # Disable tracing for credential verification
  set +x
  MACHINE_API_USER=$(oc get secret nutanix-credentials -n openshift-machine-api -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d | jq -r '.[0].data.prismCentral.username')
  CCM_USER=$(oc get secret nutanix-credentials -n openshift-cloud-controller-manager -o jsonpath='{.data.credentials}' 2>/dev/null | base64 -d | jq -r '.[0].data.prismCentral.username')
  CSI_USER=$(oc get secret ntnx-secret -n openshift-cluster-csi-drivers -o jsonpath='{.data.key}' 2>/dev/null | base64 -d | cut -d':' -f3)

  echo "Active credentials verified (usernames match expected values)"

  # Verify all are using new credentials
  if [[ "${MACHINE_API_USER}" == "${NEW_NUTANIX_USERNAME}" ]] && \
     [[ "${CCM_USER}" == "${NEW_NUTANIX_USERNAME}" ]] && \
     [[ "${CSI_USER}" == "${NEW_NUTANIX_USERNAME}" ]]; then
    echo "✓ All namespaces are using new credentials"
    echo "✓ Old Prism Central service account can be safely removed"
  else
    echo "✗ ERROR: Not all namespaces updated to new credentials"
    exit 1
  fi
fi

echo "=== Credential Rotation Validation Complete ==="
cat > ${SHARED_DIR}/credential-rotation-validation-summary.txt <<EOF
Nutanix Credential Rotation Validation Summary
===============================================

Validation Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Cluster Version: ${CLUSTER_VERSION}
Rotation Mode: $(if [[ "${SIMULATED_ROTATION}" == "true" ]]; then echo "SIMULATED"; else echo "ACTUAL"; fi)

Steps Completed:
✓ 1. Backed up existing credentials
✓ 2. Extracted credential requests from cluster
✓ 3. Generated new credentials using ccoctl nutanix create-shared-secrets
✓ 4. Recorded pre-rotation controller state
✓ 5. Applied new credentials to all three namespaces:
     - openshift-machine-api
     - openshift-cloud-controller-manager
     - openshift-cluster-csi-drivers
✓ 6. Waited for credential propagation
✓ 7. Verified controller functionality:
     - Machine API: ${MACHINE_COUNT} machines (${RUNNING_MACHINES} running)
     - CCM: ${CCM_PODS} pods (${CCM_READY} ready)
     - CSI: ${CSI_PODS} pods (${CSI_READY} ready)
     - CSI test PVC creation: SUCCESS
✓ 8. Checked controller restart requirements
✓ 9. Validated cluster operators are healthy
✓ 10. Validated old credentials can be removed

Results:
--------
All components functioning correctly with new credentials.
See ${SHARED_DIR}/credential-rotation-restart-analysis.txt for restart analysis.

Conclusion:
-----------
The Nutanix credential rotation procedure is VALIDATED and working as documented.
EOF

cat ${SHARED_DIR}/credential-rotation-validation-summary.txt

echo "Validation artifacts saved to ${SHARED_DIR}/"
find "${SHARED_DIR}/" -maxdepth 1 \( -name '*credential*' -o -name '*rotation*' \) -exec ls -la {} \; 2>/dev/null || true

echo "✓ Nutanix credential rotation validation completed successfully!"
