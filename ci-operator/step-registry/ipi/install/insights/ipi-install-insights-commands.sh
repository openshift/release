#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
if [[ -f "${cluster_profile}/insights-live.yaml" ]]; then
    oc create -f "${cluster_profile}/insights-live.yaml" || true
fi
