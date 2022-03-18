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

echo "Jenkins image from CI pipeline:jenkins: ${JENKINS_IMAGE}"
if [[ -z ${JENKINS_IMAGE} ]]; then
    echo "No jenkins image env var found, not overriding jenkins imagestream for e2e test of jenkins-sync-plugin."
else
    echo "Tagging the CI generated Jenkins image ${JENKINS_IMAGE} from pipeline:jenkins into the test cluster's jenkins imagestream in the openshift namespace"
    echo "Current contents of the jenkins imagestream in the openshift namespace"
    oc describe is jenkins -n openshift
    echo "Tagging ${JENKINS_IMAGE} into the jenkins imagestream in the openshift namespace"
    oc tag --source=docker ${JENKINS_IMAGE} openshift/jenkins:2
    # give some time for the image import to finish; watching from the CLI is non-trivial
    sleep 30
    echo "New contents of the jenkins imagestream in the openshift namespace"
    oc describe is jenkins -n openshift
fi

make test-e2e

echo "Step jenkins-sync-plugin-e2e completed."
