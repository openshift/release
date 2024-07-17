#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0
export VSPHERE_PERSIST_SESSION=true
export SSL_CERT_FILE=/var/run/vsphere-ibmcloud-ci/vcenter-certificate

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
}

dir=/tmp/installer
mkdir "${dir}/"

# set invalid networks
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-networks.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  vsphere:
    failureDomains:
    - topology:
        networks:
        - invalid network
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "unable to find network provided" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check networks field"
else
  echo "Fail: failed to check networks field"
  check_result=$((check_result + 1))
fi
set -o errexit
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid vcenter
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-vcenter.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  vsphere:
    vcenters:
    - server: 1&invalid-vcenter
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "must be the domain name or IP address of the vCenter" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check vcenter field"
else
  echo "Fail: failed to check vcenter field"
  check_result=$((check_result + 1))
fi
set -o errexit
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid cluster name
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-cluster-name.yaml.patch"

cat >"${PATCH}" <<EOF
metadata:
  name: invalid.name
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "cluster name must not contain '.'" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check cluster name"
else
  echo "Fail: failed to check cluster name"
  check_result=$((check_result + 1))
fi
set -o errexit
rm -rf "${dir:?}/"
mkdir "${dir}/"

exit "${check_result}"
