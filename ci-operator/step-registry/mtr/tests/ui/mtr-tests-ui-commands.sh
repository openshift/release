#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the TARGET_URL value using the $SHARED_DIR/console.url file
URL=$(cat $SHARED_DIR/console.url)
TARGET_URL=${URL#"https://console-openshift-console."}

# Set the scope
export CYPRESS_INCLUDE_TAGS=$MTR_TESTS_UI_SCOPE

# Execute Cypress
echo "Executing Cypress tests..."
npx cypress run \
    --config video=false \
    --spec $CYPRESS_SPEC \
    --env windupUrl=$TARGET_URL

# Combine results into one JUnit results file
echo "Merging results reports..."
npm run mergereports

# Copy combined report into $SHARED_DIR
echo "Archiving /tmp/windup-ui-tests/cypress/reports/junitreport.xml to ARTIFACT_DIR/windup-ui-results.xml..."
cp /tmp/windup-ui-tests/cypress/reports/junitreport.xml $ARTIFACT_DIR/windup-ui-results.xml