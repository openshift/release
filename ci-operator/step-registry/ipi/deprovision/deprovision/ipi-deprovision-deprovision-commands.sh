#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deprovisioning cluster ..."
cp -ar "${SHARED_DIR}" /tmp/installer
openshift-install --dir /tmp/installer destroy cluster
