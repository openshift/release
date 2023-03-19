#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

addon \
    --addon "$ADDON_NAME" \
    --cluster "$CLUSTER_NAME" \
    --token "$OCM_TOKEN" \
    --api-host "$API_HOST" \
    --timeout "$TIMEOUT" \
    uninstall
