#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/proxy_private_url" ]]; then
  echo "'${SHARED_DIR}/proxy_private_url' not found, abort." && exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")
cat >> "${CONFIG}" << EOF
proxy:
  httpProxy: ${proxy_private_url}
  httpsProxy: ${proxy_private_url}
EOF
