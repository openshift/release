#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

PATCH="${SHARED_DIR}/install-config-patch.yaml"
if [[ "${CREDENTIALS_MODE}" != "" ]]; then
  cat > "${PATCH}" << EOF
credentialsMode: ${CREDENTIALS_MODE}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  echo "Updated credentialsMode in '${CONFIG}'."
fi

echo "The updated credentialsMode:"
yq-go r "${CONFIG}" credentialsMode
