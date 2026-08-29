#!/bin/bash
set -euo pipefail

if [[ -z "${CATALOG_INDEX_IMAGE:-}" ]]; then
    echo "ERROR: CATALOG_INDEX_IMAGE is required but not set"
    exit 1
fi

echo "Creating ImageDigestMirrorSet for OpenShift Pipelines..."
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: pipelines-mirror
spec:
  imageDigestMirrors:
  - source: registry.stage.redhat.io/openshift-pipelines
    mirrors:
    - quay.io/openshift-pipeline
  - source: registry.redhat.io/openshift-pipelines
    mirrors:
    - quay.io/openshift-pipeline
EOF

echo "Waiting for MachineConfigPool to finish updating after IDMS apply..."
for i in $(seq 1 60); do
    UPDATING=$(oc --request-timeout=12s get mcp worker \
        -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "Unknown")
    DEGRADED=$(oc --request-timeout=12s get mcp worker \
        -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "Unknown")
    UPDATED=$(oc --request-timeout=12s get mcp worker \
        -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}' 2>/dev/null || echo "Unknown")

    if [[ "${DEGRADED}" == "True" ]]; then
        echo "ERROR: MachineConfigPool 'worker' is Degraded"
        oc --request-timeout=12s get mcp worker \
            -o jsonpath='{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || true
        echo ""
        exit 1
    fi

    if [[ "${UPDATED}" == "True" && "${UPDATING}" == "False" ]]; then
        echo "MachineConfigPool 'worker' is Updated after $((10*i)) seconds"
        break
    fi

    if [[ $i -eq 60 ]]; then
        echo "WARNING: MachineConfigPool not Updated within 10 minutes, proceeding anyway"
        break
    fi
    echo "  MCP status: Updated=${UPDATED}, Updating=${UPDATING} - waiting... (attempt ${i}/60)"
    sleep 10
done

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
