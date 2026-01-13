#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-quayio-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quayio-secret/password)
QUAY_API_TOKEN=$(cat /var/run/quay-qe-quayio-secret/oauth2token)
GITHUB_ACCESS_TOKEN=$(cat /var/run/quay-qe-quayio-secret/accesstoken)

DOCKER_USERNAME=$(cat /var/run/quay-qe-dockerio-secret/username)
DOCKER_PASSWORD=$(cat /var/run/quay-qe-dockerio-secret/password)

function copyArtifacts {
    cp -r ./cypress/results/* $ARTIFACT_DIR || true
}

#Archive the testing report XML file
trap copyArtifacts EXIT

export QUAY_USERNAME="$QUAY_USERNAME"
export QUAY_PASSWORD="$QUAY_PASSWORD"
export DOCKER_USERNAME="$DOCKER_USERNAME"
export DOCKER_PASSWORD="$DOCKER_PASSWORD"

python3 --version
python3 utility/quayio_test_push_images.py -n 20 > $ARTIFACT_DIR/quayio_push_image_report || true

export SOURCE_REPO="quay.io/quay-qetest/node"
mkdir -p cypress/downloads
python3 utility/quayio_test_pull_images.py -n 50 > $ARTIFACT_DIR/quay_io_pull_image_report || true

#Clone Quay-test repo to get the local test images
git clone https://"$GITHUB_ACCESS_TOKEN"@github.com/quay/quay-tests.git
cd quay-tests/quay-io-tests && mkdir -p cypress/downloads && mkdir -p cypress/results 
yarn install

export CYPRESS_QUAY_API_TOKEN="$QUAY_API_TOKEN"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
NO_COLOR=1 yarn run all > $ARTIFACT_DIR/quayio_testing_report
