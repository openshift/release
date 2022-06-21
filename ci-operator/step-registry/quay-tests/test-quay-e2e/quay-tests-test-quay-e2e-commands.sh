#!/bin/bash

set -euo pipefail

#Set Kubeconfig:
cd quay-frontend-tests
#test skoepo to push image to quay
skopeo -v
skopeo copy docker://quay.io/quay-qetest/postgres:latest --dest-tls-verify=false --dest-creds quay:password docker://quay370.apps.quayperf370.perfscale.devcluster.openshift.com/qateam/test
cp -L $KUBECONFIG /tmp/kubeconfig && export KUBECONFIG_PATH=/tmp/kubeconfig

#Create Artifact Directory:
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR


function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR && cp -r ./cypress/videos/smoke/* $ARTIFACT_DIR
}

# Install Dependcies defined in packages.json
yarn install

#Finally Copy the Junit Testing XML files and Screenshots to /tmp/artifacts
trap copyArtifacts EXIT

#Trigget Quay E2E Testing
set +x
quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}')
echo "The Quay hostname is $quay_route"
quay_hostname=${quay_route#*//}
echo "The Quay hostname is $quay_hostname"
export CYPRESS_QUAY_ENDPOINT=$quay_hostname
yarn run smoke || exit 0

