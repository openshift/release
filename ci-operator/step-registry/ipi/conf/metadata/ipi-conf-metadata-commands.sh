#!/bin/bash

set -o nounset
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ -z "$PREFIX" ]]; then
  echo "metadata PREFIX is an empty string, exiting"
  exit 1
fi

echo "Updating metadata for install-config.yaml"
PATCH="${SHARED_DIR}/install-config-metadata.yaml.patch"
cat > "${PATCH}" << EOF
metadata:
  name: ${PREFIX}-${CLUSTER_NAME}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
# Remove this after debugging is complete
echo "${CONFIG}"
