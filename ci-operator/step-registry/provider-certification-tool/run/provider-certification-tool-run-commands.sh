#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Run the tool in dedicated mode with watch flag set.
./openshift-provider-cert-linux-amd64 run --watch --dedicated > /dev/null

# Retrieve after successful execution
mkdir -p "${ARTIFACT_DIR}/certification-results"
./openshift-provider-cert-linux-amd64 retrieve "${ARTIFACT_DIR}/certification-results"

# Run results summary (to log to file)
./openshift-provider-cert-linux-amd64 results "${ARTIFACT_DIR}"/certification-results/*.tar.gz
