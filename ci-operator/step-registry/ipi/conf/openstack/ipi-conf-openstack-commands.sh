#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



# We have to truncate cluster name to 14 chars, because there is a limitation in the install-config
# Now it looks like "ci-op-rl6z646h-65230".
# We will remove "ci-op-" prefix from there to keep just last 14 characters. and it cannot start with a "-"
UNSAFE_CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}
SAFE_CLUSTER_NAME=${UNSAFE_CLUSTER_NAME#"ci-op-"}
echo "${SAFE_CLUSTER_NAME}" > ${SHARED_DIR}/CLUSTER_NAME

if [ -f "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml" ]; then
  cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml"  "${SHARED_DIR}/clouds.yaml"
fi

