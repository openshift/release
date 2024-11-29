#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/disktype.yaml.patch"

if [ -n "${DISK_TYPE}" ]; then
    cat > "${PATCH}" << EOF
platform:
  vsphere:
    diskType: ${DISK_TYPE}
EOF

    yq-go m -x -i "${CONFIG}" "${PATCH}"
    cat "${PATCH}"
fi
