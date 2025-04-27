#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
if [[ "$COMPUTE_ZONE" != "" ]]; then
  PATCH="${SHARED_DIR}/install-config-compute-zone.yaml"
  cat >"${PATCH}" <<EOF
compute:
- platform:
    vsphere:
      zones:
$(
    for zone in $COMPUTE_ZONE; do
        echo "        - $zone"
    done
)
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated compute zones in '${CONFIG}'"
fi

if [[ "$CONTROL_PLANE_ZONE" != "" ]]; then
  PATCH="${SHARED_DIR}/install-config-control-plane-zone.yaml"
  cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    vsphere:
      zones:
$(
    for zone in $CONTROL_PLANE_ZONE; do
        echo "        - $zone"
    done
)
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated control plane zones in '${CONFIG}'"
fi

if [[ "$DEFAULT_ZONE" != "" ]]; then
  PATCH="${SHARED_DIR}/install-config-default-zone.yaml"
  cat >"${PATCH}" <<EOF
platform:
  vsphere:
    defaultMachinePlatform:
      zones:
$(
    for zone in $DEFAULT_ZONE; do
        echo "        - $zone"
    done
)
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated default zones in '${CONFIG}'"
fi
