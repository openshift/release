#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/customized-resource.yaml.patch"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

cat > "${PATCH}" << EOF
controlPlane:
  name: master
  platform:
    vsphere:
      cpus: ${CONTROL_PLANE_CPU}
      memoryMB: ${CONTROL_PLANE_MEMORY}
      osDisk:
        diskSizeGB: ${CONTROL_PLANE_DISK_SIZE}
compute:
- name: worker
  platform:
    vsphere:
      cpus: ${COMPUTE_NODE_CPU}
      memoryMB: ${COMPUTE_NODE_MEMORY}
      osDisk:
        diskSizeGB: ${COMPUTE_NODE_DISK_SIZE}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

