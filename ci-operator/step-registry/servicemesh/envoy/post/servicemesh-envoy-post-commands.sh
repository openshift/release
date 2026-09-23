#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

oc delete project "${MAISTRA_NAMESPACE}"
echo "Deleted \"$MAISTRA_NAMESPACE\" Namespace"
