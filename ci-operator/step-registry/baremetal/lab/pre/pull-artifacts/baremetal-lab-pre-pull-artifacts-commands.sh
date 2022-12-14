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

PATH=/tmp:${PATH}
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" \
  --command=openshift-install --to=/tmp

gnu_arch=$(echo "${architecture}" | sed 's/arm64/aarch64/;s/amd64/x86_64/')
kernel=$(openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.kernel.location")
initramfs=$(openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.initramfs.location")
rootfs=$(openshift-install coreos print-stream-json | jq -r ".architectures.${gnu_arch}.artifacts.metal.formats.pxe.rootfs.location")

timeout -s 9 15m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${NAMESPACE}" "$kernel" "$initramfs" "$rootfs" << 'EOF'
  set -o nounset
  set -o errexit
  set -o pipefail
  wget -qO "/opt/tftpboot/${1}/vmlinuz" "${2}"
  wget -qO "/opt/tftpboot/${1}/initramfs.img" "${3}"
  wget -qO "/opt/html/${1}/rootfs.img" "${4}"
EOF
