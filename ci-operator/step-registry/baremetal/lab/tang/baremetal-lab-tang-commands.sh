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
  echo "Trying Butane version: ${butane_version}"
  all_success=true

  for role in "${roles[@]}"; do
    bu_file="${workdir}/${role}_tang_disk_encryption.bu"
    yml_file="${workdir}/manifest_${role}_tang_disk_encryption.yml"

    cat > "$bu_file" << EOF
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

    if ! butane "$bu_file" > "$yml_file"; then
      echo "Butane failed for ${role} using version '${butane_version}' (non-GA?)."
      all_success=false
      break
    fi

    cp -f "$yml_file" "${SHARED_DIR}/manifest_${role}_tang_disk_encryption.yml"
  done

  if $all_success; then
    echo "Succeeded using Butane version '${butane_version}'"
    ret_code=0
    break
  fi
done

if [ $ret_code -ne 0 ]; then
  echo "Butane failed for all provided versions. Aborting."
  exit 1
fi
