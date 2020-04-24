#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export AWS_SHARED_CREDENTIALS_FILE=$cluster_profile/.awscred
export AZURE_AUTH_LOCATION=$cluster_profile/osServicePrincipal.json
export GOOGLE_CLOUD_KEYFILE_JSON=$cluster_profile/gce.json

echo "Deprovisioning cluster ..."
if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

cp -ar "${SHARED_DIR}" /tmp/installer
openshift-install --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
