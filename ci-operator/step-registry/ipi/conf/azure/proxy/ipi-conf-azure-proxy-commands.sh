#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

proxy_private_url_file="${SHARED_DIR}/proxy_private_url"
if [ ! -f "${proxy_private_url_file}" ]; then
    echo "Did not found proxy setting from ${proxy_private_url_file}"
    exit 1
else
    PROXY_URL=$(< "${proxy_private_url_file}")
fi

if [ -z "${PROXY_URL}" ]; then
    echo "Empty proxy setting!"
    exit 1
else
    cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${PROXY_URL}
  httpsProxy: ${PROXY_URL}
  noProxy: test.no-proxy.com
EOF
fi
