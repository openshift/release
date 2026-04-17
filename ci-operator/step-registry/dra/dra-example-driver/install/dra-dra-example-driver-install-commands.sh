#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "dra-example-driver Installation via Helm"
echo "========================================="
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Enable DynamicResourceAllocation feature gate
echo "Enabling DynamicResourceAllocation feature gate..."
oc patch featuregates cluster --type='merge' -p '{"spec":{"featureSet":"CustomNoUpgrade","customNoUpgrade":{"enabled":["DRAExtendedResources"]}}}'
oc wait co kube-apiserver --for='condition=Progressing=True' --timeout=5m || true
oc wait co kube-apiserver --for='condition=Progressing=False' --timeout=30m
echo "DynamicResourceAllocation feature gate enabled"
echo ""

DRA_EXAMPLE_DRIVER="dra-example-driver"
DRA_EXAMPLE_DRIVER_NAMESPACE="${DRA_EXAMPLE_DRIVER}"

# Check if dra-example-driver is already installed
if oc get namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" &>/dev/null; then
  echo "INFO: ${DRA_EXAMPLE_DRIVER_NAMESPACE} namespace already exists"
  if helm list -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}" 2>/dev/null | grep -q "${DRA_EXAMPLE_DRIVER}"; then
    echo "INFO: dra-example-driver is already installed, skipping installation"
    exit 0
  fi
fi

# Install Helm if not present
if ! command -v helm &> /dev/null; then
  echo "Installing Helm..."
  HELM_VERSION="3.17.3"
  HELM_ARCHIVE="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}"
  curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}.sha256sum" | (cd /tmp && sha256sum --check --status)
  tar -xzf "/tmp/${HELM_ARCHIVE}" -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf "/tmp/${HELM_ARCHIVE}" /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

# Download dra-example-driver source tarball
DRA_EXAMPLE_DRIVER_VERSION="${DRA_EXAMPLE_DRIVER_VERSION:-v0.2.1}"
echo "Downloading dra-example-driver ${DRA_EXAMPLE_DRIVER_VERSION}..."
curl -fsSL "https://github.com/kubernetes-sigs/dra-example-driver/archive/refs/tags/${DRA_EXAMPLE_DRIVER_VERSION}.tar.gz" -o /tmp/dra-example-driver.tar.gz
tar -xzf /tmp/dra-example-driver.tar.gz -C /tmp
DRA_CHART_DIR="/tmp/dra-example-driver-${DRA_EXAMPLE_DRIVER_VERSION#v}/deployments/helm/${DRA_EXAMPLE_DRIVER}"
echo "Chart directory: ${DRA_CHART_DIR}"
ls "${DRA_CHART_DIR}/Chart.yaml"

echo ""

# Create namespace
echo "Creating namespace ${DRA_EXAMPLE_DRIVER_NAMESPACE}..."
if ! oc create namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" 2>/dev/null; then
  if oc get namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" &>/dev/null; then
    echo "Namespace ${DRA_EXAMPLE_DRIVER_NAMESPACE} already exists"
  else
    echo "ERROR: Failed to create namespace ${DRA_EXAMPLE_DRIVER_NAMESPACE}"
    exit 1
  fi
fi

# Add privileged SCC for dra-example-driver service account (required for OpenShift)
echo "Adding privileged SCC for dra-example-driver service account..."
oc adm policy add-scc-to-user privileged -z ${DRA_EXAMPLE_DRIVER}-service-account -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}"

echo ""

# Install dra-example-driver via Helm from local chart
echo "Installing dra-example-driver ${DRA_EXAMPLE_DRIVER_VERSION}..."
helm upgrade --install \
  --namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" \
  "${DRA_EXAMPLE_DRIVER}" \
  "${DRA_CHART_DIR}" \
  --wait \
  --timeout 10m

echo ""
echo "dra-example-driver installed successfully"

# Wait for dra-example-driver pods to be ready
echo ""
echo "Waiting for dra-example-driver pods to be ready..."
oc wait --for=condition=Ready pods \
  --all \
  -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}" \
  --timeout=10m

echo "All dra-example-driver pods are ready"

# List pods
echo ""
echo "dra-example-driver pods:"
oc get pods -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}"

# Wait for DeviceClass to be created
echo ""
echo "Waiting for DeviceClass to be created..."
timeout 5m bash -c '
while true; do
  DEVICE_CLASSES=$(oc get deviceclass -o name 2>/dev/null | grep example || true)
  if [ -n "${DEVICE_CLASSES}" ]; then
    echo "DeviceClass created: ${DEVICE_CLASSES}"
    break
  fi
  echo "Waiting for DeviceClass..."
  sleep 10
done
'

# Show DeviceClass
echo ""
echo "DeviceClass details:"
oc get deviceclass -o yaml 2>/dev/null | grep -A5 "name.*example" || true

# Wait for ResourceSlices to be published by dra-example-driver
echo ""
echo "Waiting for dra-example-driver ResourceSlices..."
timeout 5m bash -c '
while true; do
  RESOURCE_SLICES=$(oc get resourceslice -o json 2>/dev/null | grep -c "example.com" || true)
  if [ "${RESOURCE_SLICES}" -gt 0 ]; then
    echo "Found ${RESOURCE_SLICES} dra-example-driver ResourceSlice(s)"
    break
  fi
  echo "Waiting for dra-example-driver ResourceSlices..."
  sleep 10
done
'

echo ""
echo "ResourceSlices:"
oc get resourceslice

echo ""
echo "========================================="
echo "dra-example-driver Installation Complete"
echo "========================================="
echo ""
echo "Summary:"
echo "  - Namespace: ${DRA_EXAMPLE_DRIVER_NAMESPACE}"
echo "  - Version: ${DRA_EXAMPLE_DRIVER_VERSION}"
echo "  - Chart: ${DRA_CHART_DIR}"
echo ""
