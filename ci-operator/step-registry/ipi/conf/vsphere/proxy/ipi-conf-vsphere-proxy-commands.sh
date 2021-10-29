#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

PROXY_CREDS_PATH=/var/run/vault/vsphere/proxycreds

proxy_user=$(grep -oP 'user\s*:\s*\K.*' ${PROXY_CREDS_PATH})
proxy_password=$(grep -oP 'password\s*:\s*\K.*' ${PROXY_CREDS_PATH})

PROXY_URL="http://${proxy_user}:${proxy_password}@172.31.249.80:3128"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${PROXY_URL}
  httpsProxy: ${PROXY_URL}
  noProxy: test.no-proxy.com
EOF
