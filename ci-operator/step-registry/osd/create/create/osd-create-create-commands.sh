#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

set -x

echo 'Allo!'
export HOME=${SHARED_DIR}

echo 'Something' > ${HOME}/x
echo 'Something else' > ${SHARED_DIR}/y


echo "Please job delete the pod associated with this prowjob on the build farm in the ci namespace. I'll wait here."
sleep 3000
echo "Ooops.. you didn't interrupt me. This will not reproduce the problem."