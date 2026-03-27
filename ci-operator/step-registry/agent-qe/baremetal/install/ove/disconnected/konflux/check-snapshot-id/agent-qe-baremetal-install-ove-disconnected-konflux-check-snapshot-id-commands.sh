#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

[ -z "${SNAPSHOT}" ] && { echo "\$SNAPSHOT is not filled. Failing."; exit 1; }

echo "Konflux snapshot ID: ${SNAPSHOT}"



