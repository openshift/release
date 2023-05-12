#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

echo "${CLUSTER_NAME_PREFIX}-$(mktemp -u XXXXX | tr '[:upper:]' '[:lower:]')" > ${SHARED_DIR}/cluster-name

cat ${SHARED_DIR}/cluster-name
