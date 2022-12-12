#!/bin/bash

set -o errexit
set -o pipefail
set -o nounset

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

echo "Extracting the installer..."
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" \
  --command=openshift-install --to=/tmp

gnu_arch=$(echo "${architecture}" | sed 's/arm64/aarch64/;s/amd64/x86_64/')
kernel=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.kernel.location")
initramfs=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.initramfs.location")
rootfs=$(/tmp/openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.rootfs.location")

echo "Pulling the kernel, initramfs and rootfs in the auxiliary host"
timeout -s 9 30m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "$kernel" "$initramfs" "$rootfs" << 'EOF'
  set -o nounset
  set -o errexit
  set -o pipefail
  wget -O "/opt/tftpboot/${1}/vmlinuz" "${2}"
  wget -O "/opt/tftpboot/${1}/initramfs.img" "${3}"
  wget -O "/opt/html/${1}/rootfs.img" "${4}"
EOF
