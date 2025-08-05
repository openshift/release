#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_install() {
  local ret
  echo "install-config.yaml"
  echo "-------------------"
  grep -v "password\|username\|pullSecret\|auth" <"${dir}"/install-config.yaml
  set +o errexit
  openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
  wait "$!"
  ret="$?"
  echo "Installer exit with code $ret"
  set -o errexit
}

check_result=0

dir=/tmp/installer
mkdir "${dir}/"
# set invalid GPUs
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-GPUs.yaml.patch"

cat >"${PATCH}" <<EOF
compute:
- name: worker
  platform:
    nutanix:
      gpus:
        - type: InvalidType
          deviceID: 7864
        - type: Name
          name: "Invalid Name"
        - type: DeviceID
          deviceID: 9999
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep 'invalid gpu identifier type, the valid values: \\"DeviceID\\", \\"Name\\"' "${dir}"/.openshift_install.log && grep 'platform.nutanix.gpus.name: Invalid value: \\"Invalid Name\\"' "${dir}"/.openshift_install.log && grep 'platform.nutanix.gpus.deviceID: Invalid value: 9999' "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check GPUs field"
else
  echo "Fail: failed to check GPUs field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

exit "${check_result}"
