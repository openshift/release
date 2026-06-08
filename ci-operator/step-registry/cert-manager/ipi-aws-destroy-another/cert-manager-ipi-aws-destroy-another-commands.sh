#!/bin/bash

set -euo pipefail

echo "Deprovisioning second cluster..."

if [[ ! -s "${SHARED_DIR}/metadata-cluster2.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata-cluster2.json not found."
  exit 0
fi

INSTALL_DIR=/tmp/installer-cluster2
mkdir -p "${INSTALL_DIR}"
cp "${SHARED_DIR}/metadata-cluster2.json" "${INSTALL_DIR}/metadata.json"

if [[ -z "${AWS_CONFIG_FILE:-}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

echo "Running openshift-install destroy cluster for second cluster..."
openshift-install destroy cluster --dir="${INSTALL_DIR}" --log-level=info 2>&1 | tee "${ARTIFACT_DIR}/cluster2-destroy.log" &

set +e
wait "$!"
ret="$?"
set -e

exit "$ret"
