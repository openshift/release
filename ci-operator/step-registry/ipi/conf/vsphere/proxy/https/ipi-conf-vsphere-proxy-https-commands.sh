#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

PROXY_CREDS_PATH=/var/run/vault/vsphere/proxycreds
ADDITIONAL_CA_PATH=/var/run/vault/vsphere/additional_ca

proxy_user=$(grep -oP 'user\s*:\s*\K.*' ${PROXY_CREDS_PATH})
proxy_password=$(grep -oP 'password\s*:\s*\K.*' ${PROXY_CREDS_PATH})
additional_ca=$(cat ${ADDITIONAL_CA_PATH})

http_proxy_url="http://${proxy_user}:${proxy_password}@172.31.249.80:3128"
https_proxy_url="https://${proxy_user}:${proxy_password}@172.31.249.80:3130"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${http_proxy_url}
  httpsProxy: ${https_proxy_url}
  noProxy: test.no-proxy.com
additionalTrustBundle: |
$(echo $additional_ca | base64 -d | sed 's/^/  &/g')
EOF
