#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

OCM_TOKEN="/var/run/secrets/ci.openshift.io/cluster-profile/ocm-token"
cp $OCM_TOKEN "${CLUSTER_PROFILE_DIR}/ocm_token}"