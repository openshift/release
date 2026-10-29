#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-customized-resource.yaml"

cat > "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    nutanix:
      cpus: $CONTROL_PLANE_CPU
      coresPerSocket: $CONTROL_PLANE_CORESPERSOCKET
      memoryMiB: $CONTROL_PLANE_MEMORY
      osDisk:
        diskSizeGiB: $CONTROL_PLANE_DISK_SIZE
  replicas: $CONTROL_PLANE_REPLICAS
compute:
- name: worker
  platform:
    nutanix:
      cpus: $COMPUTE_CPU
      coresPerSocket: $COMPUTE_CORESPERSOCKET
      memoryMiB: $COMPUTE_MEMORY
      osDisk:
        diskSizeGiB: $COMPUTE_DISK_SIZE
  replicas: $COMPUTE_REPLICAS
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
