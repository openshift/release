#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Login to cluster
eval "$(cat "${SHARED_DIR}/api.login")"

# Populate operator version labels
if [ -f "${SHARED_DIR}/operator-versions" ]; then
    cat "${SHARED_DIR}/operator-versions" >> "${SHARED_DIR}/firewatch-additional-labels"
fi

# Populate cluster version label
cluster_version=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}')
if [ -z "$cluster_version" ]; then
    echo "ocp-v${cluster_version}" >> "${SHARED_DIR}/firewatch-additional-labels"
fi