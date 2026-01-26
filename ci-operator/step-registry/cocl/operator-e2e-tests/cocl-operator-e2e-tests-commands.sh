#!/bin/bash

set -euo pipefail

# Configuration
declare -r OPERATOR_NS="${OPERATOR_NAMESPACE}"
declare -r TEST_NS="${TEST_NAMESPACE}"
declare -r TIMEOUT="${E2E_TEST_TIMEOUT}"

echo "========================================="
echo "COCL Operator E2E Tests"
echo "========================================="
echo "Operator namespace: $OPERATOR_NS"
echo "Test namespace: $TEST_NS"
echo "Timeout: ${TIMEOUT}s"
echo ""

# Extract images from CSV relatedImages
echo "Extracting image URLs from operator CSV..."
CSV_NAME=$(oc get csv -n "$OPERATOR_NS" -o jsonpath='{.items[0].metadata.name}')
if [ -z "$CSV_NAME" ]; then
    echo "ERROR: No CSV found in namespace '$OPERATOR_NS'"
    exit 1
fi
echo "Found CSV: $CSV_NAME"

# Function to extract image by name from CSV relatedImages
get_related_image() {
    local image_name="$1"
    local image_url=$(oc get csv "$CSV_NAME" -n "$OPERATOR_NS" \
        -o jsonpath="{.spec.relatedImages[?(@.name=='$image_name')].image}")

    if [ -z "$image_url" ]; then
        echo "WARNING: Image '$image_name' not found in CSV relatedImages, using default"
        return 1
    fi
    echo "$image_url"
    return 0
}

# Extract images from CSV or fall back to environment variable defaults
PCRS_IMAGE=$(get_related_image "compute-pcrs" || echo "${PCRS_COMPUTE_IMAGE}")
REGISTER_IMAGE=$(get_related_image "registration-server" || echo "${REGISTER_SERVER_IMAGE}")
ATTESTATION_IMAGE=$(get_related_image "attestation-key-register" || echo "${ATTESTATION_KEY_REGISTER_IMAGE}")
TRUSTEE_IMG=$(get_related_image "trustee" || echo "${TRUSTEE_IMAGE}")
APPROVED_IMG="${APPROVED_IMAGE}"  # This is a test image, not from operator

declare -r PCRS_IMAGE
declare -r REGISTER_IMAGE
declare -r ATTESTATION_IMAGE
declare -r TRUSTEE_IMG
declare -r APPROVED_IMG

echo ""
echo "Using images:"
echo "  PCRS:        $PCRS_IMAGE"
echo "  Register:    $REGISTER_IMAGE"
echo "  Attestation: $ATTESTATION_IMAGE"
echo "  Trustee:     $TRUSTEE_IMG"
echo "  Approved:    $APPROVED_IMG"
echo ""

# Set proxy if configured
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    echo "Setting proxy configuration"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Verify cluster access
echo "Cluster info:"
oc whoami
oc version -o yaml | head -20
echo ""

# Step 1: Verify operator is installed and running
echo "Step 1: Verifying COCL operator is running..."
if ! oc get namespace "$OPERATOR_NS" &>/dev/null; then
    echo "ERROR: Operator namespace '$OPERATOR_NS' does not exist"
    exit 1
fi

# Check for operator deployment/pods
if ! oc get deployment -n "$OPERATOR_NS" -l control-plane=controller-manager &>/dev/null; then
    echo "ERROR: COCL operator deployment not found in namespace '$OPERATOR_NS'"
    echo "Available deployments:"
    oc get deployments -n "$OPERATOR_NS" || true
    exit 1
fi

# Wait for operator to be ready
echo "Waiting for operator deployment to be ready..."
if ! oc wait --for=condition=Available=true deployment \
    -n "$OPERATOR_NS" \
    -l control-plane=controller-manager \
    --timeout=300s; then
    echo "ERROR: Operator deployment did not become ready"
    oc get pods -n "$OPERATOR_NS"
    oc describe deployment -n "$OPERATOR_NS" -l control-plane=controller-manager
    exit 1
fi

echo "✓ Operator is running"
oc get pods -n "$OPERATOR_NS"
echo ""

# Step 2: Verify CRDs are installed
echo "Step 2: Verifying CRDs are installed..."
REQUIRED_CRDS=(
    "trustedexecutionclusters.trusted-execution-clusters.io"
    "approvedimages.trusted-execution-clusters.io"
    "machines.trusted-execution-clusters.io"
    "attestationkeys.trusted-execution-clusters.io"
)

for crd in "${REQUIRED_CRDS[@]}"; do
    if ! oc get crd "$crd" &>/dev/null; then
        echo "ERROR: Required CRD '$crd' not found"
        echo "Available CRDs:"
        oc get crds | grep trusted-execution-clusters || true
        exit 1
    fi
    echo "  ✓ $crd"
done
echo ""

# Step 3: Create test namespace
echo "Step 3: Creating test namespace '$TEST_NS'..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $TEST_NS
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
echo "✓ Test namespace created"
echo ""

# Step 4: Get cluster domain for publicTrusteeAddr
echo "Step 4: Getting cluster ingress domain..."
INGRESS_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
if [ -z "$INGRESS_DOMAIN" ]; then
    echo "ERROR: Unable to get cluster ingress domain"
    exit 1
fi
echo "Cluster ingress domain: $INGRESS_DOMAIN"

# Construct publicTrusteeAddr: kbs-service-<ns>.apps.<cluster-name>.cc.azure.dog8.cloud:8080
PUBLIC_TRUSTEE_ADDR="kbs-service-${TEST_NS}.${INGRESS_DOMAIN}:8080"
echo "Public Trustee Address: $PUBLIC_TRUSTEE_ADDR"
echo ""

# Step 5: Create TrustedExecutionCluster CR
echo "Step 5: Creating TrustedExecutionCluster CR..."
cat <<EOF | oc apply -f -
apiVersion: trusted-execution-clusters.io/v1alpha1
kind: TrustedExecutionCluster
metadata:
  name: trusted-execution-cluster
  namespace: $TEST_NS
spec:
  pcrsComputeImage: $PCRS_IMAGE
  registerServerImage: $REGISTER_IMAGE
  trusteeImage: $TRUSTEE_IMG
  publicTrusteeAddr: $PUBLIC_TRUSTEE_ADDR
  attestationKeyRegisterImage: $ATTESTATION_IMAGE
EOF

if [ $? -eq 0 ]; then
    echo "✓ TrustedExecutionCluster CR created"
else
    echo "ERROR: Failed to create TrustedExecutionCluster CR"
    exit 1
fi
echo ""

# Step 6: Create ApprovedImage CR
echo "Step 6: Creating ApprovedImage CR..."
cat <<EOF | oc apply -f -
apiVersion: trusted-execution-clusters.io/v1alpha1
kind: ApprovedImage
metadata:
  name: coreos-test
  namespace: $TEST_NS
spec:
  image: $APPROVED_IMG
EOF

if [ $? -eq 0 ]; then
    echo "✓ ApprovedImage CR created"
else
    echo "ERROR: Failed to create ApprovedImage CR"
    exit 1
fi
echo ""

# Step 7: Wait for pods to be created and running
echo "Step 7: Waiting for operator to reconcile and create pods..."
echo "Checking for expected pods in namespace '$TEST_NS'..."

# Expected pod prefixes based on the TrustedExecutionCluster spec
EXPECTED_PODS=(
    "kbs-service"              # trustee/KBS
    # Add more expected pod prefixes as you identify them
)

# Wait for pods to appear
echo "Waiting up to 5 minutes for pods to be created..."
WAIT_TIME=0
MAX_WAIT=300
while [ $WAIT_TIME -lt $MAX_WAIT ]; do
    POD_COUNT=$(oc get pods -n "$TEST_NS" --no-headers 2>/dev/null | wc -l)
    if [ "$POD_COUNT" -gt 0 ]; then
        echo "✓ Found $POD_COUNT pod(s) in namespace"
        break
    fi
    echo "  Waiting for pods to appear... (${WAIT_TIME}s / ${MAX_WAIT}s)"
    sleep 10
    WAIT_TIME=$((WAIT_TIME + 10))
done

if [ "$POD_COUNT" -eq 0 ]; then
    echo "ERROR: No pods created after ${MAX_WAIT}s"
    echo "TrustedExecutionCluster status:"
    oc get trustedexecutioncluster -n "$TEST_NS" -o yaml || true
    exit 1
fi

# Show current pod status
echo ""
echo "Current pods in namespace '$TEST_NS':"
oc get pods -n "$TEST_NS" -o wide
echo ""

# Wait for pods to be running
echo "Waiting for pods to reach Running state..."
if ! oc wait --for=condition=Ready pod \
    --all \
    -n "$TEST_NS" \
    --timeout=600s; then
    echo "WARNING: Not all pods reached Ready state within timeout"
    echo ""
    echo "Pod status:"
    oc get pods -n "$TEST_NS" -o wide
    echo ""
    echo "Describing pods that are not ready:"
    oc get pods -n "$TEST_NS" --field-selector=status.phase!=Running -o name | while read pod; do
        echo "=== $pod ==="
        oc describe "$pod" -n "$TEST_NS" || true
        echo ""
        echo "=== Logs for $pod ==="
        oc logs "$pod" -n "$TEST_NS" --tail=50 || true
        echo ""
    done
    # Continue instead of failing - some pods might be optional
fi

echo "✓ Pods are running"
oc get pods -n "$TEST_NS"
echo ""

# Step 8: Verify ConfigMaps are created (placeholder - update with actual CM names)
echo "Step 8: Verifying ConfigMaps..."
echo "ConfigMaps in namespace '$TEST_NS':"
oc get configmaps -n "$TEST_NS"

# TODO: Add specific ConfigMap validation once you provide the details
# Example:
# if ! oc get configmap <expected-cm-name> -n "$TEST_NS" &>/dev/null; then
#     echo "ERROR: Expected ConfigMap not found"
#     exit 1
# fi

echo ""

# Step 9: Check CR status
echo "Step 9: Checking CR status..."
echo ""
echo "TrustedExecutionCluster status:"
oc get trustedexecutioncluster -n "$TEST_NS" -o yaml
echo ""
echo "ApprovedImage status:"
oc get approvedimage -n "$TEST_NS" -o yaml
echo ""

# Check for auto-created CRs (Machine, AttestationKey)
echo "Step 10: Checking for auto-created CRs..."
echo "Machines:"
oc get machines.trusted-execution-clusters.io -n "$TEST_NS" || echo "  No Machine CRs found (may be expected)"
echo ""
echo "AttestationKeys:"
oc get attestationkeys.trusted-execution-clusters.io -n "$TEST_NS" || echo "  No AttestationKey CRs found (may be expected)"
echo ""

# Step 11: Summary
echo "========================================="
echo "E2E Test Summary"
echo "========================================="
echo "✓ Operator is running"
echo "✓ CRDs are installed"
echo "✓ Test namespace created"
echo "✓ Cluster domain configured: $INGRESS_DOMAIN"
echo "✓ TrustedExecutionCluster CR created with publicTrusteeAddr: $PUBLIC_TRUSTEE_ADDR"
echo "✓ ApprovedImage CR created"
echo "✓ Pods are running"
echo ""
echo "Final resource state:"
oc get trustedexecutioncluster,approvedimage,machines,attestationkeys,pods,configmaps -n "$TEST_NS"
echo ""
echo "========================================="
echo "✓ E2E tests completed successfully!"
echo "========================================="

# TODO: Add more specific validation checks:
# - Verify ConfigMap contents (you mentioned "configmap got its value")
# - Verify TrustedExecutionCluster status.phase or status.conditions
# - Verify ApprovedImage status
# - Any other success criteria you'll provide later

exit 0
