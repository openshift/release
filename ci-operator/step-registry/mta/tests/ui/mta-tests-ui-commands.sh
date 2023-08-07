#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the TARGET_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
TARGET_URL="http://mta-mta.${CONSOLE_URL#"https://console-openshift-console."}"

# Set the scope
export CYPRESS_INCLUDE_TAGS=$MTA_TESTS_UI_SCOPE

# Execute Cypress
# Always return true, otherwise the script will fail before it is able to archive anything
echo "Executing Cypress tests..."
npx cypress run \
    --config video=false \
    --spec $CYPRESS_SPEC \
    --env "tackleUrl=${TARGET_URL}" || true

# Combine results into one JUnit results file
echo "Merging results reports..."
npm run mergereports

# Copy combined report into $ARTIFACT_DIR
echo "Archiving /tmp/tackle-ui-tests/cypress/reports/junitreport.xml to ARTIFACT_DIR/junit_tackle_ui_results.xml..."
cp /tmp/tackle-ui-tests/cypress/reports/junitreport.xml $ARTIFACT_DIR/junit_tackle_ui_results.xml

# Copy screenshots into $ARTIFACT_DIR/screenshots
if [ -d "/tmp/tackle-ui-tests/cypress/screenshots/" ]; then
    echo "Archiving  /tmp/tackle-ui-tests/cypress/screenshots/* to ARTIFACT_DIR/screenshots"
    mkdir -p $ARTIFACT_DIR/screenshots
    cp -r /tmp/tackle-ui-tests/cypress/screenshots/* $ARTIFACT_DIR/screenshots/
fi