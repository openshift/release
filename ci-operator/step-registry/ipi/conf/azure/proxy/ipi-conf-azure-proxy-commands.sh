#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

internal_proxy_url_file="${SHARED_DIR}/internal_proxy_url"
if [ ! -f "${internal_proxy_url_file}" ]; then
    echo "Did not found proxy setting from ${internal_proxy_url_file}"
    exit 1
else
    PROXY_URL=$(< "${internal_proxy_url_file}")
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
