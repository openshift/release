#!/bin/bash
set -euo pipefail

echo "Installing BGP Cloud Connector operator from bundle: ${BCC_BUNDLE_IMAGE}"

# Create the operator namespace
oc create namespace openshift-bgp-cloud-connector --dry-run=client -o yaml | oc apply -f -

# Install the operator using operator-sdk run bundle
operator-sdk run bundle "${BCC_BUNDLE_IMAGE}" \
  -n openshift-bgp-cloud-connector \
  --timeout=10m \
  --security-context-config restricted \
  --install-mode OwnNamespace

# Wait for the controller-manager to be available
echo "Waiting for BCC controller-manager to become available..."
oc -n openshift-bgp-cloud-connector wait \
  --for=condition=Available \
  deployment/openshift-bgp-cloud-connector-controller-manager \
  --timeout=5m

echo "BGP Cloud Connector operator installed successfully"
