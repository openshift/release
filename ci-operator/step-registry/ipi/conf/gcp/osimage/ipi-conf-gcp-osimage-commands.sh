#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/osimage.yaml.patch"

if [ -n "${COMPUTE_OSIMAGE}" ]; then
  name=$(basename ${COMPUTE_OSIMAGE})
  project=$(echo "${COMPUTE_OSIMAGE}" | cut -d/ -f2)
  cat > "${PATCH}" << EOF
compute:
- platform:
    gcp:
      osImage:
        name: ${name}
        project: ${project}
EOF
fi

if [ -n "${CONTROL_PLANE_OSIMAGE}" ]; then
  name=$(basename ${CONTROL_PLANE_OSIMAGE})
  project=$(echo "${CONTROL_PLANE_OSIMAGE}" | cut -d/ -f2)
  cat >> "${PATCH}" << EOF
controlPlane:
  platform:
    gcp:
      osImage:
        name: ${name}
        project: ${project}
EOF
fi

if [ -n "${DEFAULT_MACHINE_OSIMAGE}" ]; then
  name=$(basename ${DEFAULT_MACHINE_OSIMAGE})
  project=$(echo "${DEFAULT_MACHINE_OSIMAGE}" | cut -d/ -f2)
  cat >> "${PATCH}" << EOF
platform:
  gcp:
    defaultMachinePlatform:
      osImage:
        name: ${name}
        project: ${project}
EOF
fi

if [ -s "${PATCH}" ]; then
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  yq-go r "${CONFIG}" compute
  yq-go r "${CONFIG}" controlPlane
  yq-go r "${CONFIG}" platform

  rm "${PATCH}"
fi