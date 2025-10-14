#!/bin/bash
set -e
set -o pipefail

echo "Setup compute-nto pipeline environment"

echo "${CLUSTER_NAME}" > ${SHARED_DIR}/cluster_name
echo "${VERSION}" > ${SHARED_DIR}/cluster_version

echo "Cluster name"
cat ${SHARED_DIR}/cluster_name

echo "Cluster version"
cat ${SHARED_DIR}/cluster_version