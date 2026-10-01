#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch-project.yaml"

if [[ "${PROJECT_NAME}" != "" ]]; then
    cat >"${PATCH}" <<EOF
platform:
  nutanix:
    defaultMachinePlatform:
      project:
        name: ${PROJECT_NAME}
        type: name
EOF
fi
if [[ "${PROJECT_UUID}" != "" ]]; then
    cat >"${PATCH}" <<EOF
platform:
  nutanix:
    defaultMachinePlatform:
      project:
        uuid: ${PROJECT_UUID}
        type: uuid
EOF
fi

yq-go m -x -i "${CONFIG}" "${PATCH}"
echo "Updated project in '${CONFIG}'."

echo "The updated project:"
yq-go r "${CONFIG}" platform.nutanix.defaultMachinePlatform.project
