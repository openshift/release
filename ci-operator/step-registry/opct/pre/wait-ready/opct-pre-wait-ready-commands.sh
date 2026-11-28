#!/bin/bash

#
# Wait for cluster operators is reporting as stable before
# provisioning the test environment.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# In disconnected environments the API hostname is resolvable only from the
# private DNS zone; route API requests through the bastion proxy.
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# Ensure all Cluster Operators are ready
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
