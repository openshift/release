#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/proxy_private_url" ]]; then
  echo "'${SHARED_DIR}/proxy_private_url' not found, abort." && exit 1
fi

# TODO: move to image
curl -L https://github.com/mikefarah/yq/releases/download/3.3.0/yq_linux_amd64 -o /tmp/yq && chmod +x /tmp/yq

CONFIG="${SHARED_DIR}/install-config.yaml"
PATCH=/tmp/install-config-proxy.yaml.patch

proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")
cat > "${PATCH}" << EOF
proxy:
  httpProxy: ${proxy_private_url}
  httpsProxy: ${proxy_private_url}
EOF

/tmp/yq m -x -i "${CONFIG}" "${PATCH}"
