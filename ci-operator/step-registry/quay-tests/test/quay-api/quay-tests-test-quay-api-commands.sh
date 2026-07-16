#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)

echo "Running Quay Automation API testing cases......"
cd quay-api-tests
QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute)
echo "The Quay Route is $QUAY_ROUTE"
QUAY_APP_HOSTNAME=${QUAY_ROUTE#*//}
export CYPRESS_QUAY_ENDPOINT="$QUAY_ROUTE"
export CYPRESS_QUAY_HOSTNAME="$QUAY_APP_HOSTNAME"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"
export CYPRESS_QUAY_VERSION="$QUAY_VERSION"

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p $ARTIFACT_DIR

function copyArtifacts {
    JUNIT_PREFIX="junit_"
    # Copy XML test results with junit_ prefix for Prow reporting
    for file in cypress/results/*.xml; do
        if [ -f "$file" ]; then
            base=$(basename "$file")
            cp "$file" "$ARTIFACT_DIR/${JUNIT_PREFIX}${base}"
        fi
    done
    # Copy the console log with .log extension
    if [ -f quay_api_testing_report ]; then
        cp quay_api_testing_report "$ARTIFACT_DIR/quay_api_testing_report.log"
    fi
    # Copy cypress videos if they exist
    if ls cypress/videos/* 1>/dev/null 2>&1; then
        mkdir -p "$ARTIFACT_DIR/quay_api_testing_cypress_videos"
        cp cypress/videos/* "$ARTIFACT_DIR/quay_api_testing_cypress_videos/" || true
    fi
}

trap copyArtifacts EXIT

npm install

# Determine which Cypress spec to use based on Quay version
CYPRESS_SPEC="cypress/e2e/quay_api_testing_all.cy.js"
QUAY_MINOR_VERSION=$(echo "${QUAY_VERSION}" | cut -d'.' -f2)
if [[ "${QUAY_MINOR_VERSION}" -ge 16 ]]; then
    echo "Using new UI spec for Quay version ${QUAY_VERSION}"
    CYPRESS_SPEC="cypress/e2e/quay_api_testing_all_new_ui.cy.js"
else
    echo "Using standard spec for Quay version ${QUAY_VERSION}"
fi

NO_COLOR=1 npx cypress run --spec "${CYPRESS_SPEC}" --browser chrome --headless --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json > \
    quay_api_testing_report || true
