#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the TARGET_URL value using the cluster_url
TARGET_URL="http://mtr-mtr.$(cat ${SHARED_DIR}/cluster_url)"

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
echo "Copying /tmp/windup-ui-tests/cypress/reports/junitreport.xml to SHARED_DIR/windup-ui-results.xml..."
cp /tmp/windup-ui-tests/cypress/reports/junitreport.xml $SHARED_DIR/windup-ui-results.xml