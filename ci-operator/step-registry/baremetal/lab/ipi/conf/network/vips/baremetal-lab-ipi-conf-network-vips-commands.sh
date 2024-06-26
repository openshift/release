#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to cobfigure networking: ${SHARED_DIR}/install-config.yaml"

# shellcheck disable=SC2154
cat > "${SHARED_DIR}/dual_vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
    $([ "${ipv4_enabled}" == "true" ] && yq_value="$(yq ".api_vip" "${SHARED_DIR}/vips.yaml")" && [ -n "$yq_value" ] && echo "- $yq_value")
    $([ "${ipv6_enabled}" == "true" ] && yq_value="$(yq ".api_vip_v6" "${SHARED_DIR}/vips.yaml")" && [ -n "$yq_value" ] && echo "- $yq_value")
    ingressVIPs:
    $([ "${ipv4_enabled}" == "true" ] && yq_value="$(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")" && [ -n "$yq_value" ] && echo "- $yq_value")
    $([ "${ipv6_enabled}" == "true" ] && yq_value="$(yq ".ingress_vip_v6" "${SHARED_DIR}/vips.yaml")" && [ -n "$yq_value" ] && echo "- $yq_value")
EOF
