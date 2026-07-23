#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z ${CLUSTER_OS_IMAGE} ]]; then
    echo "Unable to get CLUSTER_OS_IMAGE!"
    exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-osimage.yaml.patch"

cat > "${PATCH}" << EOF
platform:
  azure:
    clusterOSImage: ${CLUSTER_OS_IMAGE}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"
