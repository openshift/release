#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# install jq if not installed
if ! [ -x "$(command -v jq)" ]; then
    mkdir -p /tmp/bin
    JQ_CHECKSUM="2f312b9587b1c1eddf3a53f9a0b7d276b9b7b94576c85bda22808ca950569716"
    curl -Lo /tmp/bin/jq "https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64"

    actual_checksum=$(sha256sum /tmp/bin/jq | cut -d ' ' -f 1)
    if [ "${actual_checksum}" != "${JQ_CHECKSUM}" ]; then
        echo "Checksum of downloaded JQ didn't match expected checksum"
        exit 1
    fi

    chmod +x /tmp/bin/jq
    export PATH=${PATH}:/tmp/bin
fi

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# ensure leases file is present
if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
  echo "Couldn't find lease config file"
  exit 1
fi

# ensure hostname can be found
HOSTNAME="$(jq -r ".\"${LEASED_RESOURCE}\".hostname" "${CLUSTER_PROFILE_DIR}/leases")"
if [[ -z "${HOSTNAME}" ]]; then
  echo "Couldn't retrieve hostname from lease config"
  exit 1
fi

REMOTE_LIBVIRT_URI="qemu+tcp://${HOSTNAME}/system"
echo "Using libvirt connection for $REMOTE_LIBVIRT_URI"

# Test the possibly flakey bastion connection before tearing down
mock-nss.sh virsh -c ${REMOTE_LIBVIRT_URI} list --all || return

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi
cp -ar "${SHARED_DIR}" /tmp/installer
set +e
mock-nss.sh openshift-install --dir /tmp/installer destroy cluster
ret="$?"
set -e

if [[ ! -s "/tmp/installer/.openshift_install.log" ]]; then
  cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"
fi

exit "$ret"