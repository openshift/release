#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REMOTE_LIBVIRT_URI=$(yq r "${SHARED_DIR}/cluster-config.yaml" 'REMOTE_LIBVIRT_URI')
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
