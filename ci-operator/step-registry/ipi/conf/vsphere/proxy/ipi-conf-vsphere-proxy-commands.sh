#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

proxy_creds=$(< /var/run/vault/vsphere/proxy_creds)
proxy_ip=$(< /var/run/vault/vsphere/proxy_ip_vmc)
PROXY_URL="http://${proxy_creds}@${proxy_ip}:3128"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${PROXY_URL}
  httpsProxy: ${PROXY_URL}
  noProxy: test.no-proxy.com
EOF
