#!/bin/bash
set -euo pipefail

if [[ -z "${CATALOG_INDEX_IMAGE:-}" ]]; then
    echo "ERROR: CATALOG_INDEX_IMAGE is required but not set"
    exit 1
fi

echo "Creating CatalogSource '${CATALOG_SOURCE_NAME}' with index image: ${CATALOG_INDEX_IMAGE}"

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_SOURCE_NAME}
  namespace: openshift-marketplace
spec:
  displayName: OpenShift Pipelines Custom Catalog
  image: ${CATALOG_INDEX_IMAGE}
  publisher: OpenShift Pipelines QE
  sourceType: grpc
  grpcPodConfig:
    securityContextConfig: restricted
EOF

echo "Waiting for CatalogSource '${CATALOG_SOURCE_NAME}' to become READY..."
for i in $(seq 1 60); do
    STATE=$(oc --request-timeout=12s get catalogsource "${CATALOG_SOURCE_NAME}" \
        -n openshift-marketplace \
        -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
    if [[ "${STATE}" == "READY" ]]; then
        echo "CatalogSource '${CATALOG_SOURCE_NAME}' is READY after $((5*i)) seconds"
        exit 0
    fi
    echo "  Current state: '${STATE}' - waiting... (attempt ${i}/60)"
    sleep 5
done

echo "ERROR: CatalogSource '${CATALOG_SOURCE_NAME}' did not become READY within 5 minutes"
echo "CatalogSource status:"
oc --request-timeout=12s get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true
echo ""
echo "CatalogSource conditions:"
oc --request-timeout=12s get catalogsource "${CATALOG_SOURCE_NAME}" -n openshift-marketplace \
    -o jsonpath='{.status.conditions[*].message}' 2>/dev/null || true
echo ""
exit 1
