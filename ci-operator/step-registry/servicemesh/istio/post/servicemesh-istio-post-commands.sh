#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Check if MAISTRA_NAMESPACE exists before attempting to delete it
if oc get namespace "${MAISTRA_NAMESPACE}" > /dev/null 2>&1; then
    echo "Namespace \"${MAISTRA_NAMESPACE}\" exists. Proceeding to delete it."
    oc delete project "${MAISTRA_NAMESPACE}"
    echo "Deleted \"$MAISTRA_NAMESPACE\" Namespace"
else
    # Skip deletion if the namespace does not exist because it means that servicemesh-istio-e2e step was skipped
    echo "Namespace \"${MAISTRA_NAMESPACE}\" does not exist. No need to delete."
    exit 0
fi
