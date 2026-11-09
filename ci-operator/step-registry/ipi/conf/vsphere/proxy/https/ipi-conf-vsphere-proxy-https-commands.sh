#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

proxy_creds=$(< /var/run/vault/vsphere/proxy_creds)
proxy_ip=$(< /var/run/vault/vsphere/proxy_ip_vmc)
additional_ca="/var/run/vault/vsphere/client_ca.crt"

http_proxy_url="http://${proxy_creds}@${proxy_ip}:3128"
https_proxy_url="https://${proxy_creds}@${proxy_ip}:3130"

cat >> "${SHARED_DIR}/install-config.yaml" << EOF
proxy:
  httpProxy: ${http_proxy_url}
  httpsProxy: ${https_proxy_url}
  noProxy: test.no-proxy.com
additionalTrustBundle: |
$(sed 's/^/  &/g' ${additional_ca})
EOF
