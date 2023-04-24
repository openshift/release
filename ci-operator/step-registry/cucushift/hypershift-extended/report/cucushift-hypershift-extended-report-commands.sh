#!/bin/bash

set -xeuo pipefail

REPORT_FILE_NAME=junit_operator.xml
TEST_BEARER_TOKEN="55a6a7da-2faa-46cc-bb78-04eda767bc5f"
REPORT_PORTAL_URL=https://reportportal-openshift.apps.ocp-c1.prod.psi.redhat.com/api/v1/${PROJECT}/launch/import

sleep 1h
# find report
if [ ! -f "${SHARED_DIR}/${REPORT_FILE_NAME}" ]; then
    echo "${REPORT_FILE_NAME} not found error"
    exit 1
fi

# zip the junit file
zip junit.zip ${SHARED_DIR}/${REPORT_FILE_NAME}
curl --silent --location --request POST "${REPORT_PORTAL_URL}" --header 'Content-Type: application/json'  --header "Authorization: Bearer ${TEST_BEARER_TOKEN}" -F "file=@junit.zip;type=application/zip"

