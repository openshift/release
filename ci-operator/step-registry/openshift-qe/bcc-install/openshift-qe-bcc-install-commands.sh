#!/bin/bash
set -euo pipefail

echo "Installing BGP Cloud Connector operator from bundle: ${BCC_BUNDLE_IMAGE}"

NAMESPACE="openshift-bgp-cloud-connector"

# Create the operator namespace
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Extract bundle manifests from the bundle image using oc image extract
BUNDLE_DIR="$(mktemp -d /tmp/bcc-bundle.XXXXXX)"
echo "Extracting bundle manifests from ${BCC_BUNDLE_IMAGE} into ${BUNDLE_DIR}"
oc image extract "${BCC_BUNDLE_IMAGE}" \
  --path="/manifests/:${BUNDLE_DIR}/manifests/" \
  --confirm

# Apply CRDs first
echo "Applying CRDs..."
CRD_COUNT=0
for crd_file in "${BUNDLE_DIR}"/manifests/*crd*.yaml "${BUNDLE_DIR}"/manifests/*crd*.yml; do
  if [[ -f "${crd_file}" ]]; then
    echo "  Applying CRD: ${crd_file}"
    oc apply -f "${crd_file}"
    CRD_COUNT=$((CRD_COUNT + 1))
  fi
done
if [[ "${CRD_COUNT}" -eq 0 ]]; then
  echo "WARNING: No CRD files found in bundle manifests"
fi

# Create OperatorGroup for OwnNamespace install mode
echo "Creating OperatorGroup..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: bgp-cloud-connector-operatorgroup
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
EOF

# Find and apply the ClusterServiceVersion
echo "Applying ClusterServiceVersion..."
CSV_COUNT=0
for csv_file in "${BUNDLE_DIR}"/manifests/*clusterserviceversion*.yaml "${BUNDLE_DIR}"/manifests/*clusterserviceversion*.yml; do
  if [[ -f "${csv_file}" ]]; then
    echo "  Applying CSV: ${csv_file}"
    oc apply -n "${NAMESPACE}" -f "${csv_file}"
    CSV_COUNT=$((CSV_COUNT + 1))
  fi
done
if [[ "${CSV_COUNT}" -eq 0 ]]; then
  echo "ERROR: No ClusterServiceVersion files found in bundle manifests" >&2
  ls -la "${BUNDLE_DIR}/manifests/" >&2
  exit 1
fi

# Clean up extracted bundle
rm -rf "${BUNDLE_DIR}"

# Wait for the controller-manager to be available
echo "Waiting for BCC controller-manager to become available..."
oc -n "${NAMESPACE}" wait \
  --for=condition=Available \
  deployment/openshift-bgp-cloud-connector-controller-manager \
  --timeout=5m

echo "BGP Cloud Connector operator installed successfully"
