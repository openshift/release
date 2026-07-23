#!/bin/bash

#
# Wait for cluster operators is reporting as stable before
# provisioning the test environment.
#

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Ensure all Cluster Operators are ready
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Progressing=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
oc wait --all --for=condition=Degraded=False clusteroperators.config.openshift.io --timeout=10m > /dev/null
