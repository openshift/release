#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/confidential_compute.yaml.patch"
cat > "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      type: n2d-standard-8
      onHostMaintenance: Terminate
      confidentialCompute: Enabled
compute:
- name: worker
  platform:
    gcp:
      type: n2d-standard-8
      onHostMaintenance: Terminate
      confidentialCompute: Enabled
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
