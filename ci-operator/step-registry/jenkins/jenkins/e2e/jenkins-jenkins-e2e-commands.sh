#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs an e2e suite for OpenShift Jenkins
# The suite assumes that the Jenkins imagestream installed by the samples operator is present in the cluster.
#
# The KUBECONFIG environment variable must be set for the step to run to full completion.
#

echo "Starting step jenkins-e2e."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping e2e test of jenkins."
    exit 0
fi

make e2e

echo "Step jenkins-e2e completed."
