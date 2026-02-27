#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "NVIDIA GPU Operator Installation"
echo "========================================="
echo ""

# Install jq if not available (needed for JSON manipulation)
if ! command -v jq &> /dev/null; then
  echo "Installing jq..."
  JQ_VERSION="1.7.1"
  curl -sL "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" -o /tmp/jq
  chmod +x /tmp/jq
  export PATH="/tmp:${PATH}"
  echo "jq installed to /tmp/jq"
fi

# Export kubeconfig
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Wait for cluster to be ready
echo "Waiting for cluster to be ready..."
oc wait --for=condition=Ready nodes --all --timeout=10m

# Check if GPU Operator is already installed
if oc get namespace nvidia-gpu-operator &>/dev/null; then
  echo "INFO: nvidia-gpu-operator namespace already exists"
  if oc get csv -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator &>/dev/null; then
    echo "INFO: GPU Operator CSV already exists, checking if it's ready..."
    CSV_NAME=$(oc get csv -n nvidia-gpu-operator -l operators.coreos.com/gpu-operator-certified.nvidia-gpu-operator -o jsonpath='{.items[0].metadata.name}')
    CSV_PHASE=$(oc get csv -n nvidia-gpu-operator "${CSV_NAME}" -o jsonpath='{.status.phase}')
    if [ "${CSV_PHASE}" == "Succeeded" ]; then
      echo "INFO: GPU Operator is already installed and ready"
      # Check if ClusterPolicy exists and verify CDI is enabled
      if oc get clusterpolicy gpu-cluster-policy &>/dev/null; then
        CDI_ENABLED=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.cdi.enabled}' 2>/dev/null || echo "false")
        if [ "${CDI_ENABLED}" == "true" ]; then
          echo "INFO: ClusterPolicy exists with CDI enabled, skipping installation"
          exit 0
        else
          echo "WARNING: ClusterPolicy exists but CDI is not enabled, patching..."
          oc patch clusterpolicy gpu-cluster-policy --type=merge -p '
spec:
  operator:
    defaultRuntime: crio
  cdi:
    enabled: true
    default: false
'
          echo "INFO: ClusterPolicy patched with CDI enabled"
          exit 0
        fi
      fi
    fi
  fi
fi

echo "Installing NVIDIA GPU Operator via OLM..."
echo ""

# Step 1: Create nvidia-gpu-operator namespace
echo "Step 1: Creating nvidia-gpu-operator namespace..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# Step 2: Create OperatorGroup
echo "Step 2: Creating OperatorGroup..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

# Step 3: Get the latest channel for gpu-operator-certified
echo "Step 3: Discovering GPU Operator package information..."
CHANNEL=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
CATALOG=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.catalogSource}')
echo "  Channel: ${CHANNEL}"
echo "  Catalog: ${CATALOG}"

# Step 4: Create Subscription
echo "Step 4: Creating Subscription to gpu-operator-certified..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
EOF

# Step 5: Wait for CSV to be created
echo "Step 5: Waiting for CSV to be created..."
CSV_NAME=""
for i in $(seq 1 60); do
  CSV_NAME=$(oc get subscription gpu-operator-certified -n nvidia-gpu-operator -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
  if [ -n "${CSV_NAME}" ]; then
    echo "  CSV found: ${CSV_NAME}"
    break
  fi
  echo "  Attempt ${i}/60: Waiting for CSV..."
  sleep 10
done

if [ -z "${CSV_NAME}" ]; then
  echo "ERROR: CSV was not created within the timeout period"
  exit 1
fi

# Step 6: Wait for CSV to reach Succeeded phase
echo "Step 6: Waiting for CSV to reach Succeeded phase..."
for i in $(seq 1 40); do
  CSV_PHASE=$(oc get csv -n nvidia-gpu-operator "${CSV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "${CSV_PHASE}" == "Succeeded" ]; then
    echo "  CSV is ready: ${CSV_NAME}"
    break
  fi
  echo "  Attempt ${i}/40: Current phase: ${CSV_PHASE}"
  sleep 15
done

if [ "${CSV_PHASE}" != "Succeeded" ]; then
  echo "ERROR: CSV did not reach Succeeded phase within the timeout period"
  echo "Current CSV status:"
  oc get csv -n nvidia-gpu-operator "${CSV_NAME}" -o yaml
  exit 1
fi

echo "INFO: GPU Operator installed successfully"
echo ""

# Step 7: Create ClusterPolicy with CDI enabled
echo "Step 7: Creating ClusterPolicy with CDI enabled..."

# Get the example ClusterPolicy from CSV and modify it
oc get csv -n nvidia-gpu-operator "${CSV_NAME}" -o jsonpath='{.metadata.annotations.alm-examples}' | \
  jq '.[0]' > /tmp/clusterpolicy.json

# Modify the ClusterPolicy to enable CDI and set crio runtime
cat /tmp/clusterpolicy.json | \
  jq '.spec.operator.defaultRuntime = "crio" |
      .spec.cdi.enabled = true |
      .spec.cdi.default = false' > /tmp/clusterpolicy-modified.json

echo "Applying ClusterPolicy with the following CDI configuration:"
cat /tmp/clusterpolicy-modified.json | jq '.spec | {operator: .operator, cdi: .cdi}'

oc apply -f /tmp/clusterpolicy-modified.json

# Step 8: Wait for ClusterPolicy to be ready
echo "Step 8: Waiting for ClusterPolicy to be ready..."
echo "  This may take 10-15 minutes as GPU drivers are installed on nodes..."

# Wait up to 20 minutes for ClusterPolicy to be ready
if ! oc wait clusterpolicy --all --for=condition=Ready --timeout=20m; then
  echo "ERROR: ClusterPolicy did not become ready within timeout"
  echo ""
  echo "ClusterPolicy status:"
  oc get clusterpolicy gpu-cluster-policy -o yaml
  echo ""
  echo "GPU Operator pods status:"
  oc get pods -n nvidia-gpu-operator
  exit 1
fi

echo "INFO: ClusterPolicy is ready"
echo ""

# Step 9: Verify GPU nodes are labeled
echo "Step 9: Verifying GPU nodes are labeled..."
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | wc -l)
echo "  Found ${GPU_NODES} GPU node(s)"

if [ "${GPU_NODES}" -eq 0 ]; then
  echo "WARNING: No GPU nodes found with label nvidia.com/gpu.present=true"
  echo "This might indicate an issue with Node Feature Discovery or GPU detection"
  echo ""
  echo "All nodes:"
  oc get nodes
  echo ""
  echo "GPU Operator pods:"
  oc get pods -n nvidia-gpu-operator
else
  echo "INFO: GPU nodes are properly labeled"
  oc get nodes -l nvidia.com/gpu.present=true
fi

# Step 10: Verify CDI is enabled
echo ""
echo "Step 10: Verifying CDI is enabled in ClusterPolicy..."
CDI_ENABLED=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.cdi.enabled}')
if [ "${CDI_ENABLED}" == "true" ]; then
  echo "✓ CDI is enabled: ${CDI_ENABLED}"
else
  echo "✗ ERROR: CDI is not enabled: ${CDI_ENABLED}"
  exit 1
fi

DEFAULT_RUNTIME=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.spec.operator.defaultRuntime}')
echo "✓ Default runtime: ${DEFAULT_RUNTIME}"

echo ""
echo "========================================="
echo "GPU Operator Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: nvidia-gpu-operator"
echo "  - CSV: ${CSV_NAME}"
echo "  - ClusterPolicy: gpu-cluster-policy"
echo "  - CDI Enabled: ${CDI_ENABLED}"
echo "  - Default Runtime: ${DEFAULT_RUNTIME}"
echo "  - GPU Nodes: ${GPU_NODES}"
echo ""
