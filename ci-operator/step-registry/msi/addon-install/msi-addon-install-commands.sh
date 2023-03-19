#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

poetry run python app/cli.py addon \
    -t "$OCM_TOKEN" \
    --timeout "$TIMEOUT" \
    -a "$ADDON_NAME" \
    -c "$CLUSTER_NAME" \
    --api-host "$API_HOST" \
    install \
    -p "$ADDON_PARAMETERS"
