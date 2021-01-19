#!/bin/bash

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

echo "Deprovisioning cluster ..."

if [[ ! -s "${SHARED_DIR}"/metadata.json ]]; then
  echo "files in ${SHARED_DIR}"
  ls "${SHARED_DIR}"
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

cp -ar "${SHARED_DIR}" /tmp/installer

echo "Destroy bootstrap ..."
openshift-install --dir /tmp/installer destroy bootstrap
echo "Destroy cluster ..."
openshift-install --dir /tmp/installer destroy cluster

ret="$?"

cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
