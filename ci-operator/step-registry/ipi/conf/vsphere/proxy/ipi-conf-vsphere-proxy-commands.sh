#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Disable tracing due to proxy credential handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
proxy_creds=$(< /var/run/vault/vsphere/proxy_creds)
proxy_ip=$(< /var/run/vault/vsphere/proxy_ip_vmc)
PROXY_URL="http://${proxy_creds}@${proxy_ip}:3128"
# Restore previous tracing state
$WAS_TRACING && set -x

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${PROXY_URL}
  httpsProxy: ${PROXY_URL}
  noProxy: test.no-proxy.com
EOF
