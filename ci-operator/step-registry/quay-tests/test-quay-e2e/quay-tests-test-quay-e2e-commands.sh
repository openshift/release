#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Navigate to Quay E2E testing Directory
cd quay-frontend-tests
#Check Skopeo Version
skopeo -v

#Set Kubeconfig:
cp -L $KUBECONFIG /tmp/kubeconfig && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR

# Install Dependcies defined in packages.json
yarn install

#Trigget Quay E2E Testing
set +x
quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}')
echo "quay route name is $quay_route"
export CYPRESS_QUAY_ENDPOINT=$quay_route
yarn run smoke

#Archive testing reulsts Junit XML file and Screenshots
cp -r ./cypress/results/* $ARTIFACT_DIR && cp -r ./cypress/screenshots/* $ARTIFACT_DIR