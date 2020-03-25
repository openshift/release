#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export AWS_SHARED_CREDENTIALS_FILE=$cluster_profile/.awscred
export AZURE_AUTH_LOCATION=$cluster_profile/osServicePrincipal.json

echo "Deprovisioning cluster ..."
cp -ar "${SHARED_DIR}" /tmp/installer
openshift-install --dir /tmp/installer destroy cluster &

set +e
wait "$!"
ret="$?"
set -e

cp /tmp/installer/.openshift_install.log "${ARTIFACT_DIR}"

exit "$ret"
