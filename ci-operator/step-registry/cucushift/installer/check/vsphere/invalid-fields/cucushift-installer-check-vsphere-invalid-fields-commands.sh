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
  set -o errexit
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
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, no bootstrap role
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
yq-go d -i "${CONFIG}" "platform.vsphere.hosts.(role==bootstrap)"
run_install
if grep "a single host with the bootstrap role must be defined" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check bootstrap role"
else
  echo "Fail: failed to check bootstrap role"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, no control-plane role
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
yq-go d -i "${CONFIG}" "platform.vsphere.hosts.(role==control-plane)"
run_install
if grep "not enough hosts found (0) to support all the configured control plane replicas (3)" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check control-plane role"
else
  echo "Fail: failed to check control-plane role"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, no compute role
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
yq-go d -i "${CONFIG}" "platform.vsphere.hosts.(role==compute)"
run_install
if grep "not enough hosts found (0) to support all the configured compute replicas" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check compute role"
else
  echo "Fail: failed to check compute role"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, invalid role name
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-role-name.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    hosts:
      - role: bootstrap-invalid
      - role: control-plane-invalid
      - role: control-plane-invalid
      - role: control-plane-invalid
      - role: compute-invalid
      - role: compute-invalid
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep 'Unsupported value: \\"bootstrap-invalid\\": supported values: \\"bootstrap\\", \\"compute\\", \\"control-plane\\"' "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check bootstrap role name"
else
  echo "Fail: failed to check bootstrap role name"
  check_result=$((check_result + 1))
fi
if grep 'Unsupported value: \\"control-plane-invalid\\": supported values: \\"bootstrap\\", \\"compute\\", \\"control-plane\\"' "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check control-plane role name"
else
  echo "Fail: failed to check control-plane role name"
  check_result=$((check_result + 1))
fi
if grep 'Unsupported value: \\"compute-invalid\\": supported values: \\"bootstrap\\", \\"compute\\", \\"control-plane\\"' "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check compute role name"
else
  echo "Fail: failed to check compute role name"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, invalid failureDomain
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-failureDomain.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    hosts:
      - role: bootstrap
        failureDomain: invalid-failureDomain
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "failure domain not found" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check failureDomain"
else
  echo "Fail: failed to check failureDomain"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, invalid ipAddrs
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-ipAddrs.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    hosts:
      - role: bootstrap
        networkDevice:
          ipAddrs:
            - invalid-ipaddrs
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "invalid CIDR address" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check ipAddrs"
else
  echo "Fail: failed to check ipAddrs"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, invalid gateway
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-gateway.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    hosts:
      - role: bootstrap
        networkDevice:
          gateway: invalid-gateway
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "is not a valid IP" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check gateway"
else
  echo "Fail: failed to check gateway"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, invalid nameservers
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
PATCH="${dir}/invalid-nameservers.yaml.patch"
cat >"${PATCH}" <<EOF
platform:
  vsphere:
    hosts:
      - role: bootstrap
        networkDevice:
          nameservers:
            - invalid-nameserver-1
            - invalid-nameserver-2
            - invalid-nameserver-3
            - invalid-nameserver-4
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"
run_install
if grep "must have at most 3 items" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check nameservers"
else
  echo "Fail: failed to check nameservers"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, no networkDevice
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
yq-go d -i "${CONFIG}" "platform.vsphere.hosts.(role==bootstrap).networkDevice"
run_install
if grep "must specify networkDevice configuration" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check networkDevice missing"
else
  echo "Fail: failed to check networkDevice missing"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

# static ip, no ipAddrs
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"
CONFIG="${dir}/install-config.yaml"
yq-go d -i "${CONFIG}" "platform.vsphere.hosts.(role==bootstrap).networkDevice.ipAddrs"
run_install
if grep "must specify a IP" "${dir}"/.openshift_install.log; then
  echo "Pass: passed to check ipAddrs missing"
else
  echo "Fail: failed to check ipAddrs missing"
  check_result=$((check_result + 1))
fi
rm -rf "${dir:?}/"
mkdir "${dir}/"

exit "${check_result}"
