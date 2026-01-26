#!/bin/bash

set -euo pipefail

# Configuration
declare -r OPERATOR_NS="${OPERATOR_NAMESPACE}"
declare -r SCC_NAME="${OPERATOR_NS}-trusted-cluster-scc"

echo "========================================="
echo "Creating SecurityContextConstraints for COCL Operator"
echo "========================================="
echo "Operator namespace: $OPERATOR_NS"
echo "SCC name: $SCC_NAME"
echo ""

# Verify cluster access
echo "Cluster info:"
oc whoami
oc version --short
echo ""

# Check if namespace exists, create if not
echo "Step 1: Ensuring operator namespace exists..."
if oc get namespace "$OPERATOR_NS" &>/dev/null; then
    echo "✓ Namespace '$OPERATOR_NS' already exists"
else
    echo "Creating namespace '$OPERATOR_NS'..."
    oc create namespace "$OPERATOR_NS"
    echo "✓ Namespace created"
fi
echo ""

# Create SecurityContextConstraints
echo "Step 2: Creating SecurityContextConstraints..."

# Delete existing SCC if present
if oc get scc "$SCC_NAME" &>/dev/null; then
    echo "Existing SCC found, deleting..."
    oc delete scc "$SCC_NAME"
fi

cat <<EOF | oc apply -f -
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: $SCC_NAME
allowHostDirVolumePlugin: false
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
allowedCapabilities: []
defaultAddCapabilities: []
fsGroup:
  type: RunAsAny
priority: 10
readOnlyRootFilesystem: false
requiredDropCapabilities:
- ALL
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
volumes:
- configMap
- downwardAPI
- emptyDir
- image
- projected
- secret
users:
- system:serviceaccount:${OPERATOR_NS}:trusted-cluster-operator
EOF

if [ $? -eq 0 ]; then
    echo "✓ SecurityContextConstraints created successfully"
else
    echo "ERROR: Failed to create SecurityContextConstraints"
    exit 1
fi
echo ""

# Verify SCC was created
echo "Step 3: Verifying SCC..."
if oc get scc "$SCC_NAME" &>/dev/null; then
    echo "✓ SCC verified"
    echo ""
    echo "SCC details:"
    oc get scc "$SCC_NAME" -o yaml | head -30
else
    echo "ERROR: SCC not found after creation"
    exit 1
fi
echo ""

echo "========================================="
echo "✓ SCC setup completed successfully!"
echo "========================================="
echo "SCC Name: $SCC_NAME"
echo "Service Account: system:serviceaccount:${OPERATOR_NS}:trusted-cluster-operator"
echo ""
echo "Next step: Install the operator using OperatorGroup and Subscription"
echo "========================================="

exit 0
