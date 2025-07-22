#!/bin/bash

set -euo pipefail

QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)

declare -A versions=(
    ["stable-3.12"]="3.12"
    ["stable-3.13"]="3.13"
    ["stable-3.14"]="3.14"
    ["stable-3.15"]="3.15"
    ["stable-3.16"]="3.16"
    ["stable-3.17"]="3.17"
)

QUAY_VERSION="${versions[${QUAY_OPERATOR_CHANNEL}]:-}"
if [[ -z "$QUAY_VERSION" ]]; then
    echo "Unknown QUAY_OPERATOR_CHANNEL: ${QUAY_OPERATOR_CHANNEL}" >&2
    exit 1
fi
export CYPRESS_QUAY_VERSION="$QUAY_VERSION"

echo "Running Quay Automation API testing cases......"
cd quay-api-tests
QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute)
echo "The Quay Route is $QUAY_ROUTE"
QUAY_APP_HOSTNAME=${QUAY_ROUTE#*//}
export CYPRESS_QUAY_ENDPOINT="$QUAY_APP_HOSTNAME"
export CYPRESS_QUAY_USER="$QUAY_USERNAME"
export CYPRESS_QUAY_PASSWORD="$QUAY_PASSWORD"

yarn install
NO_COLOR=1 yarn run cypress run --spec "cypress/e2e/quay_api_testing_all.cy.js" --browser electron --headless --reporter cypress-multi-reporters --reporter-options configFile=reporter-config.json > quay_api_testing_report || true

mkdir -p $ARTIFACT_DIR/quay_api_testing_cypress_videos || true
cp cypress/results/quay_api_testing_report.xml $ARTIFACT_DIR/quay_api_testing_report.xml || true
cp quay_api_testing_report $ARTIFACT_DIR/quay_api_testing_report || true
cp cypress/videos/* $ARTIFACT_DIR/quay_api_testing_cypress_videos/ || true
