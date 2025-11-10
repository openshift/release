#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)

echo "Running Quay Automation API testing cases......"
cd quay-api-tests
QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute)
echo "The Quay Route is $QUAY_ROUTE"
QUAY_APP_HOSTNAME=${QUAY_ROUTE#*//}
export CYPRESS_QUAY_ENDPOINT="$QUAY_APP_HOSTNAME"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"
export CYPRESS_QUAY_VERSION="$QUAY_VERSION"

yarn install

# Determine which Cypress spec to use based on Quay version
CYPRESS_SPEC="cypress/e2e/quay_api_testing_all.cy.js"
if [[ "${QUAY_VERSION}" == "3.16" ]]; then
    echo "Using new UI spec for Quay version 3.16"
    CYPRESS_SPEC="cypress/e2e/quay_api_testing_all_new_ui.cy.js"
else
    echo "Using standard spec for Quay version ${QUAY_VERSION}"
fi

NO_COLOR=1 yarn run cypress run --spec "${CYPRESS_SPEC}" --browser chrome --headless --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json > \
    quay_api_testing_report || true

mkdir -p $ARTIFACT_DIR/quay_api_testing_cypress_videos || true
cp cypress/results/quay_api_testing_report.xml $ARTIFACT_DIR/quay_api_testing_report.xml || true
cp quay_api_testing_report $ARTIFACT_DIR/quay_api_testing_report || true
cp cypress/videos/* $ARTIFACT_DIR/quay_api_testing_cypress_videos/ || true
