#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/secure_boot.yaml.patch"
cat > "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      secureBoot: "Enabled"
compute:
- name: worker
  platform:
    gcp:
      secureBoot: "Enabled"
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
