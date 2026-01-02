#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

echo "Installing cluster-observability-operator via OLM v1"

# Get the catalog image from environment (set by rhobs-konflux-catalogsource or Gangway API)
# The rhobs-konflux-catalogsource step requires MULTISTAGE_PARAM_OVERRIDE_COO_INDEX_IMAGE to be set
COO_INDEX_IMAGE="${MULTISTAGE_PARAM_OVERRIDE_COO_INDEX_IMAGE:-}"

if [[ -z "${COO_INDEX_IMAGE}" ]]; then
    echo "ERROR: Catalog image not set!"
    echo "This job is designed to be triggered via Gangway API with:"
    echo "  MULTISTAGE_PARAM_OVERRIDE_COO_INDEX_IMAGE=<catalog-image-url>"
    echo ""
    echo "Example:"
    echo "  MULTISTAGE_PARAM_OVERRIDE_COO_INDEX_IMAGE=registry.stage.redhat.io/rhobs/observability-operator-catalog:v1.2.3"
    exit 1
fi

echo "Using catalog image: ${COO_INDEX_IMAGE}"

# Check if OLM v1 is available
echo "Checking for OLM v1 CRDs..."
if ! oc get crd clustercatalogs.olm.operatorframework.io &> /dev/null; then
    echo "ERROR: OLM v1 is not installed! ClusterCatalog CRD not found."
    echo "Make sure FEATURE_SET=TechPreviewNoUpgrade is set."
    exit 1
fi

if ! oc get crd clusterextensions.olm.operatorframework.io &> /dev/null; then
    echo "ERROR: OLM v1 is not fully installed! ClusterExtension CRD not found."
    exit 1
fi

echo "OLM v1 is available ✓"

# Step 1: Create namespace and service account
echo "Step 1: Creating namespace and service account..."
cat <<EOF | oc apply -f -
---
apiVersion: v1
kind: Namespace
metadata:
  name: cluster-observability-operator-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cluster-observability-operator-installer
  namespace: cluster-observability-operator-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-observability-operator-installer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: cluster-observability-operator-installer
  namespace: cluster-observability-operator-system
EOF

# Step 2: Create ClusterCatalog for cluster-observability-operator
echo "Step 2: Creating ClusterCatalog from pre-built catalog image..."

# Create ClusterCatalog pointing to the Konflux catalog image
cat <<EOF | oc apply -f -
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterCatalog
metadata:
  name: cluster-observability-operator-catalog
spec:
  source:
    type: Image
    image:
      ref: ${COO_INDEX_IMAGE}
      pollInterval: 10m
EOF

echo "Waiting for catalog to be ready (this may take a few minutes)..."
if oc wait --for=condition=Serving clustercatalog/cluster-observability-operator-catalog --timeout=5m 2>/dev/null; then
    echo "ClusterCatalog is ready ✓"
else
    echo "ClusterCatalog did not become ready within 5 minutes. Checking status..."
    oc get clustercatalog cluster-observability-operator-catalog -o yaml
    echo "Failed to get catalog ready. Please check the status above."
    exit 1
fi

# Step 3: Install cluster-observability-operator via ClusterExtension
echo "Step 3: Installing operator via ClusterExtension..."
cat <<EOF | oc apply -f -
---
apiVersion: olm.operatorframework.io/v1
kind: ClusterExtension
metadata:
  name: cluster-observability-operator
spec:
  namespace: cluster-observability-operator-system
  serviceAccount:
    name: cluster-observability-operator-installer
  source:
    sourceType: Catalog
    catalog:
      packageName: cluster-observability-operator
EOF

echo "Waiting for operator installation..."
sleep 10

# Check ClusterExtension status
echo "ClusterExtension status:"
oc get clusterextension cluster-observability-operator -o jsonpath='{.status.conditions}' | jq '.' || true

# Step 4: Verify operator pods
echo "Step 4: Checking operator pods..."
sleep 15
if oc get pods -n cluster-observability-operator-system &> /dev/null; then
    oc get pods -n cluster-observability-operator-system
    echo "Operator pods are running ✓"
else
    echo "Operator pods not found yet. Checking namespace..."
    oc get pods -n cluster-observability-operator-system || true
fi

# Step 5: Check CRDs
echo "Step 5: Checking installed CRDs..."
if oc get crd monitoringstacks.monitoring.rhobs &> /dev/null; then
    echo "MonitoringStack CRD is installed ✓"
    oc get crd | grep -E "(monitoring.rhobs|observability.openshift.io)" || true
else
    echo "MonitoringStack CRD not found yet"
fi

echo "Installation complete!"
echo ""
echo "To check the status:"
echo "  oc get clusterextension cluster-observability-operator -o yaml"
echo ""
echo "To view operator logs:"
echo "  oc logs -n cluster-observability-operator-system -l app.kubernetes.io/name=cluster-observability-operator --tail=100"

