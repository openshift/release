#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-quayio-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quayio-secret/password)
QUAY_API_TOKEN=$(cat /var/run/quay-qe-quayio-secret/oauth2token)

cd quay-io-tests && sleep 10m
yarn install

function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR
}

export CYPRESS_QUAY_API_TOKEN="$QUAY_API_TOKEN"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
yarn run all


#Archive the testing report XML file
trap copyArtifacts EXIT