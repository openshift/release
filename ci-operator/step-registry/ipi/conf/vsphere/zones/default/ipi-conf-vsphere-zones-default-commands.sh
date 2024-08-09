#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/defaultzones.yaml.patch"

cat >"${PATCH}" <<EOF
controlPlane:
  platform: {}
compute:
  - platform: {}
platform:
  vsphere:
    defaultMachinePlatform:
      zones:
       - "us-east-1"
       - "us-east-2"
       - "us-east-3"
       - "us-west-1"
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
