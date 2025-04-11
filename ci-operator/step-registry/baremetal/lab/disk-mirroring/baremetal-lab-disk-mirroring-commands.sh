#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${ENABLE_DISK_MIRRORING:-false}" != "true" ]; then
  echo "Disk mirroring is not enabled. Skipping..."
  exit 0
fi

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

workdir=`mktemp -d`

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm /tmp/pull-secret
echo "ocp_version: ${ocp_version}"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

declare -a roles=("worker")
ret_code=1
for butane_version in "${butane_version_list[@]}"; do
  for role in "${roles[@]}"; do
    cat > "${workdir}/${role}_disk_mirroring.bu" << EOF
variant: openshift
version: ${butane_version}
metadata:
  name: ${role}-disk-mirroring
  labels:
    machineconfiguration.openshift.io/role: ${role}
boot_device:
  layout: x86_64
  mirror: 
    devices: 
      - /dev/sda
      - /dev/sdb
openshift:
  fips: false 
EOF
    butane "${workdir}/${role}_disk_mirroring.bu" > "${workdir}/manifest_${role}_disk_mirroring.yml"
    ret_code=$?
    [ ${ret_code} -ne 0 ] && echo "Butane failed to transform '${role}-disk_mirroring.bu' to machineconfig file using version '${butane_version}' (non-GA?)." && break
    cp -f "${workdir}/manifest_${role}_disk_mirroring.yml" "${SHARED_DIR}/manifest_${role}_disk_mirroring.yml"
  done
  # skip other versions from the array if current one was successful (GA scenario or non-GA 2nd run)
  [ ${ret_code} -eq 0 ] && echo "Succeed to transform 'disk_mirroring.bu' to machineconfig file using version '${butane_version}'." && break
done
# abort if all versions from the array have failed
if [ ${ret_code} -ne 0 ]; then
  echo "Butane failed to transform storage templates into machineconfig files. Aborting execution."
  exit 1
fi
