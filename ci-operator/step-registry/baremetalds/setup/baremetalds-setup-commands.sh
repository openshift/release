#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ setup command ************"
env

echo ""
echo "------------ /${SHARED_DIR}"
ls -ll ${SHARED_DIR}

echo ""
echo "------------ /var/run/secrets/ci.openshift.io/cluster-profile"
ls -la /var/run/secrets/ci.openshift.io/cluster-profile





