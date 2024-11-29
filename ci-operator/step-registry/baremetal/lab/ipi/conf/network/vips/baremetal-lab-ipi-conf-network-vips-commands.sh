#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to configure ipv4 networking: ${SHARED_DIR}/vips_patch_install_config.yaml"

if [[ "${AGENT_PLATFORM_TYPE}" = "none" ]]; then
  cat > "${SHARED_DIR}/vips_patch_install_config.yaml" <<EOF
platform:
  none: {}
EOF
  exit 0
fi

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