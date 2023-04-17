#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

poetry run python app/cli.py addon \
    --addons "${ADDON1_CONFIG}" \
    --addons "${ADDON2_CONFIG}" \
    --addons "${ADDON3_CONFIG}" \
    --addons "${ADDON4_CONFIG}" \
    --cluster "${CLUSTER_NAME}" \
    --token "${OCM_TOKEN}" \
    --api-host "${API_HOST}" \
    --timeout "${TIMEOUT}" \
    --parallel "${PARALLEL}" \
    uninstall
