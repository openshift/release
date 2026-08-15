#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/ultrassd.yaml.patch"

cat > "${PATCH}" << EOF
controlPlane: 
  platform:
    azure:
      ultraSSDCapability: Enabled
compute:
- name: worker  
  platform:
    azure:
      ultraSSDCapability: Enabled
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
