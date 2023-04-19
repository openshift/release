#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Set Kubeconfig:
cd quay-frontend-tests
skopeo -v
oc version
terraform version
(cp -L $KUBECONFIG /tmp/kubeconfig || true) && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR


function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR && cp -r ./cypress/videos/smoke/* $ARTIFACT_DIR
}

# Install Dependcies defined in packages.json
yarn install || true

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

#Trigget Quay E2E Testing
set +x
quay_ns=$(oc get quayregistry --all-namespaces | tail -n1 | tr " " "\n" | head -n1)
quay_registry=$(oc get quayregistry -n "$quay_ns" | tail -n1 | tr " " "\n" | head -n1)
registryEndpoint="$(oc -n "$quay_ns" get quayregistry "$quay_registry" -o jsonpath='{.status.registryEndpoint}')"
registry="${registryEndpoint#https://}"
echo "The Quay hostname is $registryEndpoint"
export CYPRESS_QUAY_ENDPOINT=$registry
yarn run smoke || true

