#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH="${SHARED_DIR}/install-config-manual-creds.yaml.patch"

cat >> "${PATCH}" << EOF
credentialsMode: Manual
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
