#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${ENABLE_DISK_ENCRYPTION:-false}" != "true" ]; then
  echo "Disk encryption is not enabled. Skipping..."
  exit 0
fi

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

workdir=`mktemp -d`

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm /tmp/pull-secret
echo "ocp_version: ${ocp_version}"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

TANG_SERVER_KEY=$(ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "podman exec -it tang tang-show-keys 7500")

declare -a roles=("master" "worker")
ret_code=1
for butane_version in "${butane_version_list[@]}"; do
  for role in "${roles[@]}"; do
    cat > "${workdir}/${role}_tang_disk_encryption.bu" << EOF
variant: openshift
version: ${butane_version}
metadata:
  name: ${role}-disk-encryption
  labels:
    machineconfiguration.openshift.io/role: ${role}
boot_device:
  layout: $([[ "${architecture}" == "arm64" ]] && echo -n "aarch64" || echo -n "x86_64")
  luks:
    tang:
      - url: http://${AUX_HOST}:7500
        thumbprint: ${TANG_SERVER_KEY}
    threshold: 1
EOF
    butane "${workdir}/${role}_tang_disk_encryption.bu" > "${workdir}/manifest_${role}_tang_disk_encryption.yml"
    ret_code=$?
    [ ${ret_code} -ne 0 ] && echo "Butane failed to transform '${role}-tang_disk_encryption.bu' to machineconfig file using version '${butane_version}' (non-GA?)." && break
    cp -f "${workdir}/manifest_${role}_tang_disk_encryption.yml" "${SHARED_DIR}/manifest_${role}_tang_disk_encryption.yml"
  done
  # skip other versions from the array if current one was successful (GA scenario or non-GA 2nd run)
  [ ${ret_code} -eq 0 ] && echo "Succeed to transform 'tang_disk_encryption.bu' to machineconfig file using version '${butane_version}'." && break
done
# abort if all versions from the array have failed
if [ ${ret_code} -ne 0 ]; then
  echo "Butane failed to transform storage templates into machineconfig files. Aborting execution."
  exit 1
fi
