#!/bin/bash
#
# Collects ROSA-specific custom resources and events from the management
# cluster for post-failure debugging.  Captures ROSARoleConfig,
# ROSAControlPlane, and ROSAMachinePool instances with their full status
# and conditions, plus events from the ROSA and CAPI namespaces.
#
# Every command uses "|| true" so individual failures never abort
# collection of the remaining resources.

set -o nounset
set -o pipefail
set +e  # best-effort: do not abort on errors

ROSA_DIR="${ARTIFACT_DIR}/rosa-capa-resources"
mkdir -p "${ROSA_DIR}"

echo "Collecting ROSA CAPA resources..."

# ---- Namespace-wide inspect (resources + events) ----------------------------
echo "Running oc adm inspect on ns-rosa-hcp..."
oc adm inspect ns/ns-rosa-hcp --dest-dir "${ROSA_DIR}/inspect" || true

# ---- ROSA Custom Resources --------------------------------------------------
echo "Collecting ROSARoleConfigs..."
oc get rosaroleconfigs.infrastructure.cluster.x-k8s.io -A -o yaml > "${ROSA_DIR}/rosaroleconfigs.yaml" || true

echo "Collecting ROSAControlPlanes..."
oc get rosacontrolplanes.controlplane.cluster.x-k8s.io -A -o yaml > "${ROSA_DIR}/rosacontrolplanes.yaml" || true

echo "Collecting ROSAMachinePools..."
oc get rosamachinepools.infrastructure.cluster.x-k8s.io -A -o yaml > "${ROSA_DIR}/rosamachinepools.yaml" || true

# ---- Events from ROSA and CAPI namespaces -----------------------------------
echo "Collecting events from ns-rosa-hcp..."
oc get events -n ns-rosa-hcp --sort-by='.lastTimestamp' > "${ROSA_DIR}/events-ns-rosa-hcp.txt" || true

echo "Collecting events from capa-system..."
oc get events -n capa-system --sort-by='.lastTimestamp' > "${ROSA_DIR}/events-capa-system.txt" || true

echo "Collecting events from capi-system..."
oc get events -n capi-system --sort-by='.lastTimestamp' > "${ROSA_DIR}/events-capi-system.txt" || true

echo "ROSA CAPA resource collection complete."
