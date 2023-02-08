#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the TARGET_URL value using the cluster_url
TARGET_URL="http://mtr-mtr.$(cat ${SHARED_DIR}/cluster_url)"

# Installing Cypress
echo "Installing Cypress"
npx cypress install

# Execute Cypress
echo "Executing Cypress tests..."
CYPRESS_INCLUDE_TAGS=$CYPRESS_TAG npx cypress run \
    --config video=false \
    --spec $CYPRESS_SPEC \
    --env jenkinsWorkspacePath=$CYPRESS_WORKSPACE,windupUrl=$TARGET_URL

# Combine results into one JUnit results file
echo "Merging results reports..."
npm run mergereports

# Copy combined report into $SHARED_DIR
echo "Copying ${CYPRESS_WORKSPACE}/cypress/reports/junitreport.xml to SHARED_DIR/windup-ui-results.xml..."
cp $CYPRESS_WORKSPACE/cypress/reports/junitreport.xml $SHARED_DIR/windup-ui-results.xml