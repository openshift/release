#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔍 Waiting for IBM Storage Scale CRDs..."

# The FusionAccess operator installs the IBM Storage Scale operator which creates these CRDs
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s; then
  echo "✅ IBM Storage Scale CRDs are ready"
else
  echo "❌ CRDs not established within timeout"
  exit 1
fi
