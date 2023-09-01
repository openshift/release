#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the API_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
RESULTS_FILE="/spring-boot-openshift-interop-tests/junit-report.xml"
LOGS_FOLDER="/spring-boot-openshift-interop-tests/test-sb/log"
USERNAME="kubeadmin"
PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)

# Archive results function
function archive-results() {
    if [[ -f "${RESULTS_FILE}" ]] && [[ ! -f "${ARTIFACT_DIR}/junit_springboot_interop_results.xml" ]]; then
        echo "Copying ${RESULTS_FILE} to ${ARTIFACT_DIR}/junit_springboot_interop_results.xml..."
        cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/junit_springboot_interop_results.xml"

        echo "Copying ${LOGS_FOLDER} to ${ARTIFACT_DIR}/logs..."
        cp "${LOGS_FOLDER}" "${ARTIFACT_DIR}/"
    fi
}

# Execute tests
echo "Executing tests..."
trap archive-results SIGINT SIGTERM ERR EXIT
/bin/bash /spring-boot-openshift-interop-tests/interop.sh ${API_URL} springboot ${USERNAME} ${PASSWORD}

