#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml
export OVIRT_CONFIG=${SHARED_DIR}/ovirt-config.yaml

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

cp -ar "${SHARED_DIR}" /tmp/installer

# TODO: remove once BZ#1926093 is done and backported
if [[ "${CLUSTER_TYPE}" == "ovirt" ]]; then
  echo "Destroy bootstrap ..."
  set +e
  openshift-install --dir /tmp/installer destroy bootstrap
  set -e
fi

openshift-install --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
