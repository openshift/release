#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Copying source code to test pod..."

# SRC_PATH does end with /. : the content of the source directory is copied into dest directory
oc cp ./. "${MAISTRA_NAMESPACE}"/"${MAISTRA_SC_POD}":/work/

echo "Copying kubeconfig to test pod..."
oc cp ${KUBECONFIG} ${MAISTRA_NAMESPACE}/${MAISTRA_SC_POD}:/work/ci-kubeconfig

echo "Source copy completed successfully"