#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail


proxy_public_url_file="${SHARED_DIR}/proxy_public_url"

if [[ "${CLUSTER_TYPE}" == "nutanix" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/proxy_public_url" ]]; then
    # shellcheck disable=SC1091
    proxy_public_url_file="${CLUSTER_PROFILE_DIR}/proxy_public_url"
fi

if [ ! -f "${proxy_public_url_file}" ]; then
    echo "Did not found proxy setting from ${proxy_public_url_file}"
    exit 1
else
    PUBLIC_PROXY_URL=$(< "${proxy_public_url_file}")
fi

NO_PROXY_URLS="localhost,127.0.0.1"
if [[ -f "${SHARED_DIR}/additional_no_proxy_urls" ]]; then
    echo "Appending cluster's API/API-INT/APPS URLs as NO_PROXY URLs..."
    additional_no_proxy_urls=$(cat "${SHARED_DIR}/additional_no_proxy_urls")
    NO_PROXY_URLS="${NO_PROXY_URLS},${additional_no_proxy_urls}"
fi
echo "NO_PROXY_URLS: '${NO_PROXY_URLS}'"

if [ -z "${PUBLIC_PROXY_URL}" ]; then
    echo "Empty proxy setting!"
    exit 1
else
    cat > "${SHARED_DIR}/proxy-conf.sh" << EOF
export http_proxy=${PUBLIC_PROXY_URL}
export https_proxy=${PUBLIC_PROXY_URL}
export no_proxy="${NO_PROXY_URLS}"
export HTTP_PROXY=${PUBLIC_PROXY_URL}
export HTTPS_PROXY=${PUBLIC_PROXY_URL}
export NO_PROXY="${NO_PROXY_URLS}"
EOF
    cat > "${SHARED_DIR}/unset-proxy.sh" << EOF
unset http_proxy
unset https_proxy
unset no_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset NO_PROXY
EOF
fi
