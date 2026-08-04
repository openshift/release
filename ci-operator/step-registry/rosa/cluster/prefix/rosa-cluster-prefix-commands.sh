#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

STS=${STS:-true}
HOSTED_CP=${HOSTED_CP:-false}
CLUSTER_PREFIX=${CLUSTER_PREFIX:-}

# Generate prefix if CLUSTER_PREFIX is not set
if [[ -z "$CLUSTER_PREFIX" ]]; then
  CLUSTER_PREFIX="ci-rosa"
  if [[ "$HOSTED_CP" == "true" ]]; then
    CLUSTER_PREFIX="ci-rosa-h"
  elif [[ "$STS" == "true" ]]; then
    CLUSTER_PREFIX="ci-rosa-s"
  fi
  subfix=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
  CLUSTER_PREFIX="$CLUSTER_PREFIX-$subfix"
fi

echo "Cluster Prefix: $CLUSTER_PREFIX"
echo $CLUSTER_PREFIX> "${SHARED_DIR}/cluster-prefix"
