#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# shellcheck disable=SC2154
if [ "${AGENT_PLATFORM_TYPE}" = "none" ] || [ "${masters}" -eq 1 ]; then
  echo "Skip IPv6 vips configuration as the platform is none."
  exit
fi

echo "Creating patch file to configure ipv6 networking: ${SHARED_DIR}/ipv6_vips_patch_install_config.yaml"

cat > "${SHARED_DIR}/ipv6_vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
      - $(yq ".api_vip_v6" "${SHARED_DIR}/vips.yaml")
    ingressVIPs:
      - $(yq ".ingress_vip_v6" "${SHARED_DIR}/vips.yaml")
EOF
