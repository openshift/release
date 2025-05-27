#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-stagequayio-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-stagequayio-secret/password)
QUAY_API_TOKEN=$(cat /var/run/quay-qe-stagequayio-secret/oauth2token)

function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR || true
}

#Archive the testing report XML file
trap copyArtifacts EXIT

cd stage-quay-io-tests && mkdir -p cypress/downloads && mkdir -p cypress/results 
yarn install

export CYPRESS_QUAY_API_TOKEN="$QUAY_API_TOKEN"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
NO_COLOR=1 yarn run all > $ARTIFACT_DIR/stage_quayio_testing_report