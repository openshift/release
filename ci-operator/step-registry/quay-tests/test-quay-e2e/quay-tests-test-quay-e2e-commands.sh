#!/bin/bash

set -euo pipefail

#Set Kubeconfig:
cd quay-frontend-tests
skopeo -v
cp -L $KUBECONFIG /tmp/kubeconfig && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR


function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR && cp -r ./cypress/screenshots/* $ARTIFACT_DIR
}

# Install Dependcies defined in packages.json
yarn install

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

#Trigget Quay E2E Testing
set +x
quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}')
echo "The Quay route is $quay_route"
export CYPRESS_QUAY_ENDPOINT=$quay_route
yarn run smoke