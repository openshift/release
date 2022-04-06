#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail


proxy_public_url_file="${SHARED_DIR}/proxy_public_url"

if [ ! -f "${proxy_public_url_file}" ]; then
    echo "Did not found proxy setting from ${proxy_public_url_file}"
    exit 1
else
    PUBLIC_PROXY_URL=$(< "${proxy_public_url_file}")
fi

if [ -z "${PUBLIC_PROXY_URL}" ]; then
    echo "Empty proxy setting!"
    exit 1
else
    cat > "${SHARED_DIR}/proxy-conf.sh" << EOF
export http_proxy=${PUBLIC_PROXY_URL}
export https_proxy=${PUBLIC_PROXY_URL}
export no_proxy="localhost,127.0.0.1"
EOF
fi
