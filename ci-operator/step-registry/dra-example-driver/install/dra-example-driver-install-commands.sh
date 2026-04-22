#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "========================================="
echo "dra-example-driver Installation via Helm"
echo "========================================="
echo "Version: ${DRA_EXAMPLE_DRIVER_VERSION}"
echo ""

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

DRA_EXAMPLE_DRIVER_NAMESPACE="dra-example-driver"

# Check if dra-example-driver is already installed
if oc get namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" &>/dev/null; then
  echo "INFO: ${DRA_EXAMPLE_DRIVER_NAMESPACE} namespace already exists"
  if helm list -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}" 2>/dev/null | grep -q dra-example-driver; then
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
  curl -fsSL "https://get.helm.sh/${HELM_ARCHIVE}.sha256sum" -o "/tmp/${HELM_ARCHIVE}.sha256sum"
  echo "Verifying checksum..."
  (cd /tmp && sha256sum --check --status "${HELM_ARCHIVE}.sha256sum") || {
    echo "ERROR: Helm checksum verification failed"
    rm -rf "/tmp/${HELM_ARCHIVE}" "/tmp/${HELM_ARCHIVE}.sha256sum"
    exit 1
  }
  tar -xzf "/tmp/${HELM_ARCHIVE}" -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf "/tmp/${HELM_ARCHIVE}" "/tmp/${HELM_ARCHIVE}.sha256sum" /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

echo ""

# Download dra-example-driver source tarball for the Helm chart
echo "Downloading dra-example-driver ${DRA_EXAMPLE_DRIVER_VERSION}..."
curl -fsSL "https://github.com/kubernetes-sigs/dra-example-driver/archive/refs/tags/${DRA_EXAMPLE_DRIVER_VERSION}.tar.gz" -o /tmp/dra-example-driver.tar.gz
tar -xzf /tmp/dra-example-driver.tar.gz -C /tmp
DRA_CHART_DIR="/tmp/dra-example-driver-${DRA_EXAMPLE_DRIVER_VERSION#v}/deployments/helm/dra-example-driver"
echo "Chart directory: ${DRA_CHART_DIR}"
ls "${DRA_CHART_DIR}/Chart.yaml"

echo ""

# Create namespace
echo "Creating namespace ${DRA_EXAMPLE_DRIVER_NAMESPACE}..."
oc create namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" 2>/dev/null || true

# Grant privileged SCC for dra-example-driver service account (required for OpenShift)
echo "Adding privileged SCC for dra-example-driver service account..."
oc adm policy add-scc-to-user privileged -z dra-example-driver-service-account -n "${DRA_EXAMPLE_DRIVER_NAMESPACE}"

echo ""

# Install dra-example-driver via Helm from local chart
echo "Installing dra-example-driver ${DRA_EXAMPLE_DRIVER_VERSION}..."
helm upgrade --install \
  --namespace "${DRA_EXAMPLE_DRIVER_NAMESPACE}" \
  dra-example-driver \
  "${DRA_CHART_DIR}" \
  --set kubeletPlugin.containers.plugin.securityContext.privileged=true \
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
  if oc get deviceclass gpu.example.com &>/dev/null; then
    echo "DeviceClass created: gpu.example.com"
    break
  fi
  echo "Waiting for DeviceClass..."
  sleep 10
done
'

# Wait for ResourceSlices to be published
echo ""
echo "Waiting for dra-example-driver ResourceSlices..."
timeout 5m bash -c '
while true; do
  RESOURCE_SLICES=$(oc get resourceslice -o json 2>/dev/null | grep -c "example.com" || true)
  if [ "${RESOURCE_SLICES}" -gt 0 ]; then
    echo "Found dra-example-driver ResourceSlice(s)"
    break
  fi
  echo "Waiting for ResourceSlices..."
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
echo "  - DeviceClass: gpu.example.com"
echo ""
