#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z ${CLUSTER_OS_IMAGE} ]]; then
  echo "CLUSTER_OS_IMAGE is not set, skip setting clusterOSImage"
else
  CONFIG="${SHARED_DIR}/install-config.yaml"
  PATCH="${SHARED_DIR}/install-config-osimage.yaml.patch"

  cat >"${PATCH}" <<EOF
platform:
  nutanix:
    clusterOSImage: ${CLUSTER_OS_IMAGE}
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"
fi
