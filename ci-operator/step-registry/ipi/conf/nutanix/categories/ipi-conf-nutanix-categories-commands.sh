#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch-categories.yaml"
cat > "${PATCH}" << EOF
platform:
  nutanix:
    defaultMachinePlatform:
      categories:
      - key: ${CATEGORIES_KEY}
        value: ${CATEGORIES_VALUE}
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated categories in '${CONFIG}'."

echo "The updated categories:"
yq-go r "${CONFIG}" platform.nutanix.defaultMachinePlatform.categories
