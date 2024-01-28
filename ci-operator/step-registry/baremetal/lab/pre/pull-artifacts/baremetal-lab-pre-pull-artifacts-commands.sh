#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }
[ "${ADDITIONAL_WORKERS}" -gt 0 ] && [ -z "${ADDITIONAL_WORKER_ARCHITECTURE}" ] && { echo "\$ADDITIONAL_WORKER_ARCHITECTURE is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Extracting the installer..."
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" \
  --command=openshift-install --to=/tmp

function pull_artifacts() {
  gnu_arch=$(echo "${1}" | sed 's/arm64/aarch64/;s/amd64/x86_64/')
  kernel=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.kernel.location")
  initramfs=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.initramfs.location")
  rootfs=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.rootfs.location")

  echo "Pulling the kernel, initramfs and rootfs in the auxiliary host"
  timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
    "$(<"${SHARED_DIR}/cluster_name")" "$kernel" "$initramfs" "$rootfs" "${gnu_arch}" << 'EOF'
    set -o nounset
    set -o errexit
    set -o pipefail
    arch=${5}
    wget -O "/opt/dnsmasq/tftpboot/${1}/vmlinuz_${arch}" "${2}"
    wget -O "/opt/dnsmasq/tftpboot/${1}/initramfs_${arch}.img" "${3}"
    wget -O "/opt/html/${1}/rootfs-${arch}.img" "${4}"
EOF
}

pull_artifacts "${architecture}"
if [ "${ADDITIONAL_WORKERS}" -gt 0 ]; then
  pull_artifacts "${ADDITIONAL_WORKER_ARCHITECTURE}"
fi
