#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
            -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            install_yq_if_not_exists
            echo "Mapping Test Suite Name To: ACS-lp-interop"
            yq eval -px -ox -iI0 '.testsuite."+@name" = "ACS-lp-interop"' "${results_file}"
        fi
    fi
}

# Set the TARGET_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
TARGET_URL="https://mta-mta.${CONSOLE_URL#"https://console-openshift-console."}"

# Set the scope
export CYPRESS_INCLUDE_TAGS=$MTA_TESTS_UI_SCOPE

# Execute Cypress
# Always return true, otherwise the script will fail before it is able to archive anything
echo "Executing Cypress tests..."
npx cypress run \
    --config video=false,baseUrl=${TARGET_URL} \
    --spec $CYPRESS_SPEC || true

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

original_results="${ARTIFACT_DIR}/original_results"
mkdir -p "${original_results}"

for result_file in $(find "${ARTIFACT_DIR}" -type f -iname "*.xml"); do
  # Keep a copy of all the original Junit files before modifying them
  cp "${result_file}" "${original_results}"

  # Map tests if needed for related use cases
  mapTestsForComponentReadiness "${result_file}"

  # Send junit file to shared dir for Data Router Reporter step
  cp "${result_file}" "${SHARED_DIR}"
done