#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${ENABLE_DISK_ENCRYPTION:-false}" != "true" ] && [ "${ENABLE_DISK_MIRRORING:-false}" != "true" ]; then
  echo "Neither disk encryption nor disk mirroring is enabled. Skipping..."
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

ocp_version=$(oc adm release info --registry-config ${CLUSTER_PROFILE_DIR}/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "ocp_version: ${ocp_version}"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

TANG_SERVER_KEY=$(ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" "podman exec -it tang tang-show-keys 7500")

if [ "${BOOTSTRAP_IN_PLACE:-false}" == "true" ]; then
  declare -a roles=("master")
else
  declare -a roles=("master" "worker")
fi

ret_code=1

for butane_version in "${butane_version_list[@]}"; do
  echo "Trying Butane version: ${butane_version}"
  all_success=true

  for role in "${roles[@]}"; do
    bu_file="${workdir}/${role}-storage.bu"
    yml_file="${workdir}/manifest_${role}-storage.yml"

    layout_arch=$(echo -n "${architecture:-amd64}" | sed 's/arm64/aarch64/;s/amd64/x86_64/')

    cat > "$bu_file" << EOF
variant: openshift
version: ${butane_version}
metadata:
  name: ${role}-storage
  labels:
    machineconfiguration.openshift.io/role: ${role}
boot_device:
  layout: ${layout_arch}
EOF

  if [[ "${ENABLE_DISK_MIRRORING}" == "true" ]]; then
    cat >> "$bu_file" << EOF
  mirror: 
    devices: 
      - $(echo -n "${architecture:-amd64}" | sed 's/arm64/\/dev\/nvme0n1/;s/amd64/\/dev\/sda/')
      - $(echo -n "${architecture:-amd64}" | sed 's/arm64/\/dev\/nvme1n1/;s/amd64/\/dev\/sdb/')
EOF
  fi

  if [[ "${ENABLE_DISK_ENCRYPTION}" == "true" ]]; then
    cat >> "$bu_file" << EOF
  luks:
    tang:
      - url: http://${AUX_HOST}:7500
        thumbprint: ${TANG_SERVER_KEY}
    threshold: 1
EOF
  fi

    if ! butane "$bu_file" > "$yml_file"; then
      echo "Butane failed for ${role} using version '${butane_version}' (non-GA?)."
      all_success=false
      break
    fi

    cp -f "$yml_file" "${SHARED_DIR}/manifest_${role}-storage.yml"
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
