#!/bin/bash

set -euo pipefail

if [[ -z "${KUBECONFIG:-}" || ! -f "${KUBECONFIG}" ]]; then
    echo "No kubeconfig found at ${KUBECONFIG:-<unset>}, skipping gather"
    exit 0
fi

GATHER_DIR="${ARTIFACT_DIR}/capo-gather"
mkdir -p "${GATHER_DIR}"

echo "Gathering CAPO and ORC resources from management cluster..."

# Namespaces stuck in Terminating — these are the first sign of a stuck deletion.
echo "=== Namespaces in Terminating state ==="
oc get namespace --field-selector='status.phase=Terminating' -o yaml 2>/dev/null \
    > "${GATHER_DIR}/terminating-namespaces.yaml" || true
oc get namespace --field-selector='status.phase=Terminating' 2>/dev/null || true

# HostedClusters and NodePools for context.
for resource in hostedclusters nodepools; do
    echo "=== ${resource} ==="
    oc get "${resource}" -A -o yaml 2>/dev/null \
        > "${GATHER_DIR}/${resource}.yaml" || true
done

# CAPI core resources (Cluster, Machine) to trace the deletion chain.
for resource in \
    "clusters.cluster.x-k8s.io" \
    "machines.cluster.x-k8s.io"; do
    echo "=== ${resource} ==="
    name="${resource%%.*}"
    oc get "${resource}" -A -o yaml 2>/dev/null \
        > "${GATHER_DIR}/${name}.yaml" || true
done

# CAPO-specific resources. OpenStackServer carries the CAPO-managed finalizer
# (openstackserver.infrastructure.cluster.x-k8s.io) that can get permanently
# stuck if the CAPO pod is killed before the finalizer is removed.
for resource in \
    "openstackclusters.infrastructure.cluster.x-k8s.io" \
    "openstackmachines.infrastructure.cluster.x-k8s.io" \
    "openstackservers.infrastructure.cluster.x-k8s.io"; do
    echo "=== ${resource} ==="
    name="${resource%%.*}"
    oc get "${resource}" -A -o yaml 2>/dev/null \
        > "${GATHER_DIR}/${name}.yaml" || true
done

# ORC Image resources. These also carry an in-namespace finalizer (managed by
# the ORC controller) that can block namespace termination.
echo "=== images.openstack.k-orc.cloud ==="
oc get images.openstack.k-orc.cloud -A -o yaml 2>/dev/null \
    > "${GATHER_DIR}/orc-images.yaml" || true

echo "Done gathering CAPO resources"
