#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOCALNET_VLAN_INGRESS_VIP="${LOCALNET_VLAN_INGRESS_VIP:-192.168.111.4}"

CIRFILE="${SHARED_DIR}/cir"
PROXYPORT=8213
if [[ -f "${CIRFILE}" ]]; then
  PROXYPORT=$(jq -r '.extra | select( . != "") // {}' < "${CIRFILE}" | jq -r '.ofcir_port_proxy // 8213')
fi

source "${SHARED_DIR}/packet-conf.sh" && scp "${SSHOPTS[@]}" "${SHARED_DIR}/nested_kubeconfig" "root@${IP}:nested_kubeconfig"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${LOCALNET_VLAN_INGRESS_VIP}" << 'EOF' |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -euo pipefail
INGRESS_VIP="$1"

ensure_squid_dst_connect_acl() {
  local acl_name="$1" ip="$2"
  [[ -n "${ip}" ]] || return 0
  if grep -q "^acl ${acl_name} " "${HOME}/squid.conf" 2>/dev/null; then
    sed -i "s|^acl ${acl_name} dst .*|acl ${acl_name} dst ${ip}|" "${HOME}/squid.conf"
  else
    sed -i "/^acl CONNECT method CONNECT/i acl ${acl_name} dst ${ip}" "${HOME}/squid.conf"
  fi
  if ! grep -q "^http_access allow CONNECT ${acl_name}\$" "${HOME}/squid.conf"; then
    sed -i "/^http_access deny CONNECT !allowed_ssl_ports/a http_access allow CONNECT ${acl_name}" "${HOME}/squid.conf"
  fi
}

API_URL=$(yq -r '.clusters[0].cluster.server' nested_kubeconfig)
API_SERVER=$(echo "${API_URL}" | sed -E 's|^https?://||; s|:.*$||')
API_PORT=$(echo "${API_URL}" | sed -E 's|^https?://[^:/]+:||; s|/.*$||')
if [[ -z "${API_PORT}" || "${API_PORT}" == "${API_SERVER}" ]]; then
  API_PORT=6443
fi

ensure_squid_dst_connect_acl guest_hc_api "${API_SERVER}"
ensure_squid_dst_connect_acl guest_hc_ingress "${INGRESS_VIP}"

if [[ -n "${API_PORT}" ]] && ! grep -q "acl allowed_ssl_ports port.*[[:space:]]${API_PORT}\\b" "${HOME}/squid.conf"; then
  sed -i "s|^acl allowed_ssl_ports port.*|& ${API_PORT}|" "${HOME}/squid.conf"
fi

sudo setenforce 0
sudo podman stop -t 120 external-squid 2>/dev/null || true
sudo podman run -d --rm \
     --net host \
     --volume "${HOME}/squid.conf:/etc/squid/squid.conf" \
     --name external-squid \
     --dns 127.0.0.1 \
     quay.io/openshifttest/squid-proxy:multiarch
EOF

echo "Adding proxy-url in nested_kubeconfig (http://${IP}:${PROXYPORT}/)"
yq -i '.clusters[0].cluster."proxy-url" = "http://'"${IP}"':'"${PROXYPORT}"'/"' "${SHARED_DIR}/nested_kubeconfig"
