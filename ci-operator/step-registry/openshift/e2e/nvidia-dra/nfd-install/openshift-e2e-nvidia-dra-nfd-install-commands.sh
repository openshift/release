#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "Node Feature Discovery (NFD) Installation"
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

# Check if NFD is already installed
if oc get namespace openshift-nfd &>/dev/null; then
  echo "INFO: openshift-nfd namespace already exists"
  if oc get csv -n openshift-nfd -l operators.coreos.com/nfd.openshift-nfd &>/dev/null; then
    echo "INFO: NFD Operator CSV already exists, checking if it's ready..."
    CSV_NAME=$(oc get csv -n openshift-nfd -l operators.coreos.com/nfd.openshift-nfd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "${CSV_NAME}" ]; then
      CSV_PHASE=$(oc get csv -n openshift-nfd "${CSV_NAME}" -o jsonpath='{.status.phase}')
      if [ "${CSV_PHASE}" == "Succeeded" ]; then
        echo "INFO: NFD Operator is already installed and ready"
        # Check if NodeFeatureDiscovery CR exists
        if oc get nodefeaturediscovery -n openshift-nfd &>/dev/null; then
          echo "INFO: NodeFeatureDiscovery CR already exists, skipping installation"
          exit 0
        fi
      fi
    fi
  fi
fi

echo "Installing Node Feature Discovery Operator via OLM..."
echo ""

# Step 1: Create openshift-nfd namespace
echo "Step 1: Creating openshift-nfd namespace..."
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
EOF

# Step 2: Create OperatorGroup
echo "Step 2: Creating OperatorGroup..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd-group
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
EOF

# Step 3: Get the default channel for nfd
echo "Step 3: Discovering NFD Operator package information..."
CHANNEL=$(oc get packagemanifest nfd -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
CATALOG=$(oc get packagemanifest nfd -n openshift-marketplace -o jsonpath='{.status.catalogSource}')
echo "  Channel: ${CHANNEL}"
echo "  Catalog: ${CATALOG}"

# Step 4: Create Subscription
echo "Step 4: Creating Subscription to nfd..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: nfd
  source: ${CATALOG}
  sourceNamespace: openshift-marketplace
EOF

# Step 5: Wait for CSV to be created
echo "Step 5: Waiting for CSV to be created..."
CSV_NAME=""
for i in $(seq 1 60); do
  CSV_NAME=$(oc get subscription nfd -n openshift-nfd -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "")
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
  CSV_PHASE=$(oc get csv -n openshift-nfd "${CSV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
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
  oc get csv -n openshift-nfd "${CSV_NAME}" -o yaml
  exit 1
fi

echo "INFO: NFD Operator installed successfully"
echo ""

# Step 7: Create NodeFeatureDiscovery CR instance
echo "Step 7: Creating NodeFeatureDiscovery CR instance..."

# Get the example NodeFeatureDiscovery CR from CSV and apply it
oc get csv -n openshift-nfd "${CSV_NAME}" -o jsonpath='{.metadata.annotations.alm-examples}' | \
  jq '.[] | select(.kind=="NodeFeatureDiscovery")' > /tmp/nodefeaturediscovery.json

echo "Applying NodeFeatureDiscovery CR:"
cat /tmp/nodefeaturediscovery.json | jq .

oc apply -f /tmp/nodefeaturediscovery.json

# Step 8: Wait for NodeFeatureDiscovery to be available
echo "Step 8: Waiting for NodeFeatureDiscovery to be available..."
echo "  This may take a few minutes as NFD pods are deployed..."

if ! oc wait nodefeaturediscovery -n openshift-nfd --for=condition=Available --timeout=15m --all; then
  echo "ERROR: NodeFeatureDiscovery did not become available within timeout"
  echo ""
  echo "NodeFeatureDiscovery status:"
  oc get nodefeaturediscovery -n openshift-nfd -o yaml
  echo ""
  echo "NFD pods status:"
  oc get pods -n openshift-nfd
  exit 1
fi

echo "INFO: NodeFeatureDiscovery is available"
echo ""

# Step 9: Wait for NFD to label GPU nodes
echo "Step 9: Waiting for GPU nodes to be labeled by NFD..."
echo "  This may take a few minutes..."

# Wait up to 5 minutes for GPU labels to appear
GPU_NODES=0
for i in $(seq 1 30); do
  GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | wc -l)
  if [ "${GPU_NODES}" -gt 0 ]; then
    echo "  Found ${GPU_NODES} GPU node(s) with nvidia.com/gpu.present=true label"
    break
  fi
  echo "  Attempt ${i}/30: Waiting for GPU labels to appear..."
  sleep 10
done

if [ "${GPU_NODES}" -eq 0 ]; then
  echo "WARNING: No GPU nodes found with label nvidia.com/gpu.present=true after NFD installation"
  echo "This might indicate:"
  echo "  - GPU instance type doesn't have NVIDIA GPUs"
  echo "  - GPU drivers need to be installed first"
  echo "  - NFD feature detection rules need adjustment"
  echo ""
  echo "All nodes and their labels:"
  oc get nodes --show-labels
  echo ""
  echo "NFD pods:"
  oc get pods -n openshift-nfd
else
  echo "INFO: GPU nodes are properly labeled by NFD"
  oc get nodes -l nvidia.com/gpu.present=true --show-labels
fi

echo ""
echo "========================================="
echo "NFD Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: openshift-nfd"
echo "  - CSV: ${CSV_NAME}"
echo "  - NodeFeatureDiscovery CR: Created and Available"
echo "  - GPU Nodes Labeled: ${GPU_NODES}"
echo ""
