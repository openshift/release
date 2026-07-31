#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

CLUSTER_NAME="$(<"${SHARED_DIR}/cluster_name")"

timeout 10s ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" \
  "systemd-cat -t '${CLUSTER_NAME}' -p5 echo 'baremetal-lab-ipi-conf-network-vips: Configuring VIPs'" || true

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