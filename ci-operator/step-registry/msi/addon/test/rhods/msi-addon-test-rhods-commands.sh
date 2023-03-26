#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
OCM_TOKEN=$(cat /var/run/secrets/ci.openshift.io/cluster-profile/ocm-token)

# TODO: understand how RHODS test should be ran from product QE image (quay.io/modh/ods-ci:latest)
echo -e "cluster name: $CLUSTER_NAME\nocm_token: $OCM_TOKEN\naddon name: $ADDON_NAME\napi host: $API_HOST"
sleep INF
