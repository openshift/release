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

# Step 3: Wait for redhat-operators catalog source to be READY
echo "Step 3: Waiting for redhat-operators catalog source to be READY..."
CATALOG_READY=false
for retry in $(seq 1 60); do
  if ! oc get catalogsource redhat-operators -n openshift-marketplace &>/dev/null; then
    echo "  Retry ${retry}/60: redhat-operators catalog source not found, waiting..."
    sleep 10
    continue
  fi

  CATALOG_STATUS=$(oc get catalogsource redhat-operators -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
  if [ "${CATALOG_STATUS}" == "READY" ]; then
    CATALOG_READY=true
    echo "  redhat-operators catalog source is READY"
    break
  fi
  echo "  Retry ${retry}/60: Catalog status is '${CATALOG_STATUS}', waiting for READY..."
  sleep 10
done

if [[ "${CATALOG_READY}" == "false" ]]; then
  echo "ERROR: redhat-operators catalog source did not become READY after 10 minutes"
  echo ""
  echo "Available catalog sources:"
  oc get catalogsources -n openshift-marketplace
  exit 1
fi

# Step 4: Wait for NFD packagemanifest to be available
echo "Step 4: Waiting for NFD packagemanifest to be available..."
PACKAGE_EXISTS=false
for retry in $(seq 1 30); do
  if oc get packagemanifest nfd -n openshift-marketplace &>/dev/null; then
    PACKAGE_EXISTS=true
    echo "  NFD packagemanifest found in catalog"
    break
  fi
  echo "  Retry ${retry}/30: NFD packagemanifest not found, waiting for catalog sync..."
  sleep 10
done

if [[ "${PACKAGE_EXISTS}" == "false" ]]; then
  echo "ERROR: NFD packagemanifest not found after 5 minutes"
  echo "Available packagemanifests:"
  oc get packagemanifests -n openshift-marketplace | grep -i nfd || echo "  No NFD-related packages found"
  exit 1
fi

# Step 5: Get the default channel for nfd
echo "Step 5: Discovering NFD Operator package information..."
CHANNEL=$(oc get packagemanifest nfd -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
CATALOG="redhat-operators"
echo "  Channel: ${CHANNEL}"
echo "  Catalog: ${CATALOG}"

# Step 6: Create Subscription
echo "Step 6: Creating Subscription to nfd..."
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

# Step 7: Wait for CSV to be created
echo "Step 7: Waiting for CSV to be created..."
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

# Step 8: Wait for CSV to reach Succeeded phase
echo "Step 8: Waiting for CSV to reach Succeeded phase..."
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

# Step 9: Create NodeFeatureDiscovery CR instance
echo "Step 9: Creating NodeFeatureDiscovery CR instance..."

# Get the example NodeFeatureDiscovery CR from CSV and apply it
oc get csv -n openshift-nfd "${CSV_NAME}" -o jsonpath='{.metadata.annotations.alm-examples}' | \
  jq '.[] | select(.kind=="NodeFeatureDiscovery")' > /tmp/nodefeaturediscovery.json

echo "Applying NodeFeatureDiscovery CR:"
cat /tmp/nodefeaturediscovery.json | jq .

oc apply -f /tmp/nodefeaturediscovery.json

# Step 10: Wait for NodeFeatureDiscovery to be available
echo "Step 10: Waiting for NodeFeatureDiscovery to be available..."
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

# Step 11: Wait for NFD to detect NVIDIA GPUs and apply custom label
echo "Step 11: Waiting for NFD to detect NVIDIA GPUs..."
echo "  This may take a few minutes..."

# Wait up to 5 minutes for NFD to detect NVIDIA PCI devices (vendor ID 10de)
NFD_GPU_NODES=0
for i in $(seq 1 30); do
  NFD_GPU_NODES=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o name 2>/dev/null | wc -l)
  if [ "${NFD_GPU_NODES}" -gt 0 ]; then
    echo "  NFD detected ${NFD_GPU_NODES} node(s) with NVIDIA GPUs (feature.node.kubernetes.io/pci-10de.present=true)"
    break
  fi
  echo "  Attempt ${i}/30: Waiting for NFD to detect NVIDIA GPUs..."
  sleep 10
done

if [ "${NFD_GPU_NODES}" -eq 0 ]; then
  echo "ERROR: NFD did not detect any NVIDIA GPUs after 5 minutes"
  echo ""
  echo "Expected NFD label: feature.node.kubernetes.io/pci-10de.present=true"
  echo ""
  echo "All nodes and their labels:"
  oc get nodes --show-labels
  echo ""
  echo "NFD pods status:"
  oc get pods -n openshift-nfd
  exit 1
fi

# Step 11b: Label GPU nodes with nvidia.com/gpu.present=true for GPU operator
echo "Step 11b: Applying nvidia.com/gpu.present=true label to GPU nodes..."
GPU_NODE_NAMES=$(oc get nodes -l feature.node.kubernetes.io/pci-10de.present=true -o jsonpath='{.items[*].metadata.name}')
for node in ${GPU_NODE_NAMES}; do
  echo "  Labeling node: ${node}"
  oc label node "${node}" nvidia.com/gpu.present=true --overwrite
done

# Verify the custom labels were applied
GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true -o name 2>/dev/null | wc -l)
if [ "${GPU_NODES}" -eq 0 ]; then
  echo "ERROR: Failed to apply nvidia.com/gpu.present=true label to GPU nodes"
  exit 1
fi

echo "INFO: Successfully labeled ${GPU_NODES} GPU node(s)"
oc get nodes -l nvidia.com/gpu.present=true --show-labels

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
