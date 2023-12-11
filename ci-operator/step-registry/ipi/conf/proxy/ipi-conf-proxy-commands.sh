#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/proxy_public_url" ]]; then
  echo "'${SHARED_DIR}/proxy_public_url' not found, abort." && exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

proxy_private_url=$(<"${SHARED_DIR}/proxy_public_url")
cat >>"${CONFIG}" <<EOF
proxy:
  httpProxy: ${proxy_public_url}
  httpsProxy: ${proxy_public_url}
EOF
