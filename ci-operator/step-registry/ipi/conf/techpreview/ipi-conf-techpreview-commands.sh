#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# If an install config exists, update the featureSet.
CONFIG="${SHARED_DIR}/install-config.yaml"

if [ -f "${CONFIG}" ]; then
  PATCH="${SHARED_DIR}/install-config-patch.yaml"
  cat > "${PATCH}" << EOF
featureSet: ${FEATURE_SET}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated featureSet in '${CONFIG}'."

  echo "The updated featureSet:"
  yq-go r "${CONFIG}" featureSet
fi

# Write out a feature gate manifest to match the install config.
# These must match in spec else the bootstrap of the cluster will fail.
cat <<EOF > ${SHARED_DIR}/manifest_feature_gate.yaml
---
apiVersion: config.openshift.io/v1
kind: FeatureGate
metadata:
  annotations:
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
    release.openshift.io/create-only: "true"
  name: cluster
spec:
  featureSet: ${FEATURE_SET}
EOF
