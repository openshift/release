#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Delete the Maistra namespace with ignore-not-found to avoid errors if it doesn't exist
oc delete project "${MAISTRA_NAMESPACE}" --ignore-not-found
echo "Deleted \"$MAISTRA_NAMESPACE\" Namespace"
