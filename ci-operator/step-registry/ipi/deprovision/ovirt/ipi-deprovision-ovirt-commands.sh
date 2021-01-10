#!/bin/bash

set -eo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

ls "${SHARED_DIR}"

echo "Deprovisioning cluster ..."
cp -ar "${SHARED_DIR}" /tmp/installer

ls /tmp/installer

if [[ ! -s "/tmp/installer/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

echo "Destroy bootstrap ..."
openshift-install --dir /tmp/installer destroy bootstrap
echo "Destroy cluster ..."
openshift-install --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
