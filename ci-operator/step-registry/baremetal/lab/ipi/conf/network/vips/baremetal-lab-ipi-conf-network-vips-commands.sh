#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# shellcheck disable=SC2154
if [ "${AGENT_PLATFORM_TYPE}" = "none" ] || [ "${masters}" -eq 1 ]; then
  echo "Skip IPv4 vips configuration as the platform is none."
  exit
fi

echo "Creating patch file to configure ipv4 networking: ${SHARED_DIR}/vips_patch_install_config.yaml"
# shellcheck disable=SC2154
cat > "${SHARED_DIR}/vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
    $([ "${ipv4_enabled}" == "true" ] && echo "- $(yq ".api_vip" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv6_enabled}" == "true" ] && echo "- $(yq ".api_vip_v6" "${SHARED_DIR}/vips.yaml")")
    ingressVIPs:
    $([ "${ipv4_enabled}" == "true" ] && echo "- $(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")")
    $([ "${ipv6_enabled}" == "true" ] && echo "- $(yq ".ingress_vip_v6" "${SHARED_DIR}/vips.yaml")")
EOF