#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export AWS_SHARED_CREDENTIALS_FILE=$cluster_profile/.awscred
export AZURE_AUTH_LOCATION=$cluster_profile/osServicePrincipal.json

echo "Deprovisioning cluster ..."
cp -ar "${SHARED_DIR}" /tmp/installer
openshift-install --dir /tmp/installer destroy cluster
