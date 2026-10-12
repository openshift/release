#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

write_proxy_config() {
    local proxy_auth="$1"
    local proxy_host="$2"

    cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://$proxy_auth@${proxy_host}:3128/
export HTTPS_PROXY=http://$proxy_auth@${proxy_host}:3128/
export NO_PROXY="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://$proxy_auth@${proxy_host}:3128/
export https_proxy=http://$proxy_auth@${proxy_host}:3128/
export no_proxy="redhat.io,quay.io,redhat.com,svc,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"
EOF
    # Some steps need mirror-proxy-conf.sh instead of proxy-conf.sh because they want to differenciate
    # API access and Mirror access. In our case, it doesn't matter, since all traffic would go through the proxy
    # when we deploy disconnected environments.
    cp "${SHARED_DIR}/proxy-conf.sh" "${SHARED_DIR}/mirror-proxy-conf.sh"
}

if [[ -f "${SHARED_DIR}/BASTION_FIP" ]]; then
    if [[ ! -f "${SHARED_DIR}/SQUID_AUTH" ]]; then
        echo "ERROR: SQUID_AUTH not found in shared dir"
        exit 1
    fi
    echo "Ephemeral proxy detected: $(<"${SHARED_DIR}/BASTION_FIP")"
    write_proxy_config "$(<"${SHARED_DIR}/SQUID_AUTH")" "$(<"${SHARED_DIR}/BASTION_FIP")"
    exit 0
fi

# Some of our cluster profiles already have a proxy configured,
# so we don't need to create a new one, and can use the existing.
if [[ -f "${SHARED_DIR}/squid-credentials.txt" ]]; then
    export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
    proxy_host=$(yq -r ".clouds.${OS_CLOUD}.auth.auth_url" "$OS_CLIENT_CONFIG_FILE" | cut -d/ -f3 | cut -d: -f1)
    echo "Permanent proxy detected: $proxy_host"
    write_proxy_config "$(<"${SHARED_DIR}/squid-credentials.txt")" "${proxy_host}"
    exit 0
fi

echo "DEBUG: No proxy-conf.sh is needed."
