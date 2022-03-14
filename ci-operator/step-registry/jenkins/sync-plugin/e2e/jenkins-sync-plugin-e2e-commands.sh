#! /bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Runs an e2e suite for the OpenShift Jenkins Sync Plugin
# The suite assumes that the Jenkins imagestream installed by the samples operator is present in the cluster.
# 
# The KUBECONFIG environment variable must be set for the step to run to full completion.
#

echo "Starting step jenkins-sync-plugin-e2e."
if ! [[ -f ${KUBECONFIG} ]]; then
    echo "No kubeconfig found, skipping e2e test of jenkins-sync-plugin."
    exit 0
fi

echo "GGM start checking of JENKINS_IMAGE from pipeline:jenkins"
echo ${JENKINS_IMAGE}
echo "GGM end check JENKINS_IMAGE"

make test-e2e

echo "Step jenkins-sync-plugin-e2e completed."
