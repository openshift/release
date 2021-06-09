#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"

cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml"  "${SHARED_DIR}/clouds.yaml"
