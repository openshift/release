#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure networking: ${SHARED_DIR}/vips_patch_install_config.yaml"

if [[ "${AGENT_PLATFORM_TYPE}" = "none" ]]; then
  cat > "${SHARED_DIR}/vips_patch_install_config.yaml" <<EOF
platform:
  none: {}
EOF
  exit 0
fi

# Determine VIP order based on PRIMARY_NET
# For dual-stack configurations, the primary network VIPs should be listed first
case "${PRIMARY_NET:-ipv4}" in
ipv6)
  # IPv6 primary: list IPv6 VIPs first, then IPv4
  cat > "${SHARED_DIR}/vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
    $([ "${ipv6_enabled:-false}" == "true" ] && echo "- $(yq ".api_vip_v6" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv4_enabled:-false}" == "true" ] && echo "- $(yq ".api_vip" "${SHARED_DIR}/vips.yaml")")
    ingressVIPs:
    $([ "${ipv6_enabled:-false}" == "true" ] && echo "- $(yq ".ingress_vip_v6" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv4_enabled:-false}" == "true" ] && echo "- $(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")")
EOF
  ;;
*)
  # IPv4 primary (default): list IPv4 VIPs first, then IPv6
  cat > "${SHARED_DIR}/vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
    $([ "${ipv4_enabled:-false}" == "true" ] && echo "- $(yq ".api_vip" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv6_enabled:-false}" == "true" ] && echo "- $(yq ".api_vip_v6" "${SHARED_DIR}/vips.yaml")")
    ingressVIPs:
    $([ "${ipv4_enabled:-false}" == "true" ] && echo "- $(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv6_enabled:-false}" == "true" ] && echo "- $(yq ".ingress_vip_v6" "${SHARED_DIR}/vips.yaml")")
EOF
  ;;
esac