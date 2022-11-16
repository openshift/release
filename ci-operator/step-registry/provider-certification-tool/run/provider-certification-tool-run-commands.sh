#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/dedicated" ]
then
  # Run the tool in dedicated mode with watch flag set.
  echo "Found node dedicated to provider tool"
  ./openshift-provider-cert-linux-amd64 run --watch --dedicated > /dev/null
else
  echo "No nodes dedicated to provider tool"
  ./openshift-provider-cert-linux-amd64 run --watch > /dev/null
fi

# Retrieve after successful execution
mkdir -p "${ARTIFACT_DIR}/certification-results"
./openshift-provider-cert-linux-amd64 retrieve "${ARTIFACT_DIR}/certification-results"

# Run results summary (to log to file)
./openshift-provider-cert-linux-amd64 results "${ARTIFACT_DIR}"/certification-results/*.tar.gz
