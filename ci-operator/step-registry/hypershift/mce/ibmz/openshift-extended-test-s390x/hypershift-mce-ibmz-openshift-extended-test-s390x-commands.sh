#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# This workflow has no cluster_profile, so CLUSTER_TYPE is not injected by DPTP.
# Use a skeleton provider type to avoid requiring cluster profile credentials.
export CLUSTER_TYPE="${CLUSTER_TYPE:-powervs-s390x}"

# Run extended tests against the hosted cluster, matching hypershift-mce-ibmz-test.
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
    export KUBECONFIG="${SHARED_DIR}/nested_kubeconfig"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../../../openshift-extended/test/openshift-extended-test-commands.sh"
