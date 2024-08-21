#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

check_result=0

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

dir=/tmp/installer
mkdir "${dir}/"

# set invalid Prism Central
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-prismCentral.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    prismCentral:
      endpoint:
        address: invalid-prismCentral
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "must be the domain name or IP address of the Prism Central" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check prismCentral field"
else
  echo "Fail: failed to check prismCentral field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid Prism Central port
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-prismCentral-port.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    prismCentral:
      endpoint:
        port: 9441
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "timeout" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check prismCentral port field"
else
  echo "Fail: failed to check prismCentral port field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid username
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-username.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    prismCentral:
      username: invalid-username
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "invalid Nutanix credentials" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check username field"
else
  echo "Fail: failed to check username field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid password
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-password.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    prismCentral:
      password: invalid-password
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

run_install

if grep "invalid Nutanix credentials" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check password field"
else
  echo "Fail: failed to check password field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid prismElement uuid
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-prismElement.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    failureDomains:
    - name: failure-domain-1
      prismElement:
        uuid: invalid-prismElement-uuid
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "configured prism element UUID does not correspond to a valid prism element in Prism" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check prismElement field"
else
  echo "Fail: failed to check prismElement field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# set invalid subnetUUIDs
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-subnetUUIDs.yaml.patch"

cat >"${PATCH}" <<EOF
platform:
  nutanix:
    failureDomains:
    - name: failure-domain-1
      subnetUUIDs:
      - invalid-subnetUUIDs
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "configured subnet UUID does not correspond to a valid subnet in Prism" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check subnetUUIDs field"
else
  echo "Fail: failed to check subnetUUIDs field"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

exit "${check_result}"
