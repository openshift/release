#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

set -x

echo 'Goodbye!'

# ocm login created files here that we now use to delete the cluster
export HOME=${SHARED_DIR}

cat ${HOME}/x || true
cat ${SHARED_DIR}/y || true

