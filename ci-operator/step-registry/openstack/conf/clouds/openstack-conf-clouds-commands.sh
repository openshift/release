#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"

cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml" "${SHARED_DIR}/clouds.yaml"

if [ -f "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" ]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" "${SHARED_DIR}/osp-ca.crt"
	sed -i "s+cacert: .*+cacert: ${SHARED_DIR}/osp-ca.crt+" "${SHARED_DIR}/clouds.yaml"
fi
