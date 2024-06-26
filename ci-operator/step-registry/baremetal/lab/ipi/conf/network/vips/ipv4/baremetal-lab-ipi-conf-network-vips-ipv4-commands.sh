#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

echo "Creating patch file to cobfigure networking: ${SHARED_DIR}/install-config.yaml"

cat > "${SHARED_DIR}/ipv4_vips_patch_install_config.yaml" <<EOF
platform:
  baremetal:
    apiVIPs:
      - $(yq ".api_vip" "${SHARED_DIR}/vips.yaml")
    ingressVIPs:
      - $(yq ".ingress_vip" "${SHARED_DIR}/vips.yaml")
EOF
