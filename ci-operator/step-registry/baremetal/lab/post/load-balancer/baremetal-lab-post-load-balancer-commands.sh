#!/bin/bash

if [ -n "${LOCAL_TEST}" ]; then
  # Setting LOCAL_TEST to any value will allow testing this script with default values against the ARM64 bastion @ RDU2
  # shellcheck disable=SC2155
  export NAMESPACE=test-ci-op AUX_HOST=openshift-qe-bastion.arm.eng.rdu2.redhat.com \
      SHARED_DIR=${SHARED_DIR:-$(mktemp -d)} CLUSTER_PROFILE_DIR=~/.ssh
fi

set -o nounset

if [ -z "${AUX_HOST}" ]; then
    echo "AUX_HOST is not filled. Failing."
    exit 1
fi

SSHOPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-key")

BUILD_USER=ci-op
BUILD_ID="${NAMESPACE}"

timeout -s 9 180m ssh "${SSHOPTS[@]}" "root@${AUX_HOST}" bash -s -- \
  "${BUILD_ID}" "${BUILD_USER}" << 'EOF'
set -o nounset
BUILD_ID="${1}"
BUILD_USER=${2}"

devices=(eth1.br-ext eth2.br-int eth1.br-int)
for dev in ${devices[@]}; do
  interface=$(echo $dev | cut -f1 -d.)
  bridge=$(echo $dev | cut -f2 -d.)
  /usr/local/bin/ovs-docker del-port $bridge $interface haproxy-$BUILD_ID
  exit 0
done

# Remove HAProxy container
docker rm --force "haproxy-$BUILD_ID"

# shellcheck disable=SC2174
rm -rf "/var/builds/$BUILD_ID/haproxy"

EOF
