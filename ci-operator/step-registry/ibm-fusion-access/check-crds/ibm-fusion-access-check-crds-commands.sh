#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# The FusionAccess operator installs the IBM Storage Scale operator which creates these CRDs
if oc wait --for=condition=Established crd/clusters.scale.spectrum.ibm.com --timeout=600s; then
  exit 0
else
  exit 1
fi
