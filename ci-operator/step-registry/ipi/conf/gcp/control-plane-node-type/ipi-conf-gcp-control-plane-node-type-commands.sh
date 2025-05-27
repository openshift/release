#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${CONTROL_PLANE_NODE_TYPE}" ]]; then
	echo "$(date -u --rfc-3339=seconds) - CONTROL_PLANE_NODE_TYPE unspecified, nothing to do." && exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/node_type.yaml.patch"
cat >"${PATCH}" <<EOF
controlPlane:
  platform:
    gcp:
      type: ${CONTROL_PLANE_NODE_TYPE}
EOF

if echo "${CONTROL_PLANE_NODE_TYPE}" | grep gpu; then
	GPU_PATCH="${SHARED_DIR}/gpu.yaml.patch"
	cat >"${GPU_PATCH}" <<EOF
  controlPlane:
    platform:
      gcp:
        onHostMaintenance: Terminate
EOF
	yq-go m -x -i "${PATCH}" "${GPU_PATCH}"
	rm "${GPU_PATCH}"
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
yq-go r "${CONFIG}" controlPlane

rm "${PATCH}"
