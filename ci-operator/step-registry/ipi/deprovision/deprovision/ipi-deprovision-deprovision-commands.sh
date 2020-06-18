#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE=$CLUSTER_PROFILE_DIR/.awscred
export AZURE_AUTH_LOCATION=$CLUSTER_PROFILE_DIR/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$CLUSTER_PROFILE_DIR/gce.json
export HOME=/tmp
export WORKSPACE=${WORKSPACE:-/tmp}
export PATH="${PATH}:${WORKSPACE}"

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

dir=${WORKSPACE}/installer
mkdir -p "${dir}/"
cp -ar "${SHARED_DIR}"/* "${dir}/"
openshift-install --dir "${dir}" destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp "${dir}"/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
