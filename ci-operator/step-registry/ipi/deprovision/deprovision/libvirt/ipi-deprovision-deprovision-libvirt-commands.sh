#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# mikefarah/yq v4: "yq-v4" uses legacy CLI ("yq-v4 -o=y ..."). Images that only ship "yq" (e.g. OCP 4.8)
# require the v4 syntax: "yq eval -o=y ..." (plain "yq -o=y" treats the expression as a subcommand).
if ! command -v yq-v4 >/dev/null 2>&1 && ! command -v yq >/dev/null 2>&1; then
  echo "Neither yq-v4 nor yq found in PATH"
  exit 1
fi

yq_libvirt_get() {
  local field=$1
  local leases="${CLUSTER_PROFILE_DIR}/leases"
  if command -v yq-v4 >/dev/null 2>&1; then
    yq-v4 -oy ".[\"${LEASED_RESOURCE}\"].${field}" "${leases}"
  else
    yq eval -o=y ".[\"${LEASED_RESOURCE}\"].${field}" "${leases}"
  fi
}

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
HOSTNAME="$(yq_libvirt_get hostname)"
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