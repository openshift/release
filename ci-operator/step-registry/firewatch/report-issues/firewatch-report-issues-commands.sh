#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create the Jira configuration file
firewatch jira-config-gen --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}" --server-url "${FIREWATCH_JIRA_SERVER}"

report_command="firewatch report"

if [ "${FIREWATCH_PRIVATE_DECK,,}" = "true" ]; then
    report_command+=" --gcs-bucket qe-private-deck --gcs-creds-file /tmp/secrets/private-deck/creds.json"
fi

if [ "${FIREWATCH_FAIL_WITH_TEST_FAILURES,,}" = "true" ]; then
    report_command+=" --fail-with-test-failures"
fi

if [ "${FIREWATCH_FAIL_WITH_POD_FAILURES,,}" = "true" ]; then
    report_command+=" --fail-with-pod-failures"
fi

# If the user has specified verbose test failure reporting
if [ "${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING,,}" = "true" ]; then
    report_command+=" --verbose-test-failure-reporting"
    report_command+=" --verbose-test-failure-reporting-ticket-limit ${FIREWATCH_VERBOSE_TEST_FAILURE_REPORTING_LIMIT}"
fi

# If the user specified a configuration file path/url
if [ -n "${FIREWATCH_CONFIG_FILE_PATH}" ]; then
    report_command+=" --firewatch-config-path=${FIREWATCH_CONFIG_FILE_PATH}"
fi

# If the additional labels file exists, add it to the report command
if [ -f "${SHARED_DIR}/${FIREWATCH_JIRA_ADDITIONAL_LABELS_FILE}" ]; then
    report_command+=" --additional-labels-file=${SHARED_DIR}/${FIREWATCH_JIRA_ADDITIONAL_LABELS_FILE}"
fi
sleep 10
echo $report_command

eval "$report_command"
