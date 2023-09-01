#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the API_URL value using the $SHARED_DIR/console.url file
CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
KUBEADMIN_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
RESULTS_FILE="/spring-boot-openshift-interop-tests/junit-report.xml"

# Archive results function
function archive-results() {
    if [[ -f "${RESULTS_FILE}" ]] && [[ ! -f "${ARTIFACT_DIR}/junit_springboot_interop_results.xml" ]]; then
        echo "Copying ${RESULTS_FILE} to ${ARTIFACT_DIR}/junit_springboot_interop_results.xml..."
        cp "${RESULTS_FILE}" "${ARTIFACT_DIR}/junit_springboot_interop_results.xml"
    fi
}

# Execute tests
echo "Executing tests..."
trap archive-results SIGINT SIGTERM ERR EXIT
/bin/bash /spring-boot-openshift-interop-tests/interop.sh ${API_URL} springboot kubeadmin ${KUBEADMIN_PASSWORD}
