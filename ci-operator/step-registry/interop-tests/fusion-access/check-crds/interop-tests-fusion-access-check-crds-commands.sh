#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔍 Waiting for IBM Storage Scale CRDs..."

# Wait for CRDs to be established
# The FusionAccess operator installs the IBM Storage Scale operator which creates these CRDs
oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s

echo "✅ IBM Storage Scale CRDs are ready"
