#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Jira Cloud (*.atlassian.net) requires email + API token authentication
# Jira Server only requires API token authentication
if [[ "${FIREWATCH_JIRA_SERVER}" == *"atlassian.net"* ]]; then
    if [ ! -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
        echo "ERROR: Jira Cloud requires email authentication. Please ensure FIREWATCH_JIRA_EMAIL_PATH is set and the email file exists at: ${FIREWATCH_JIRA_EMAIL_PATH}"
        exit 1
    fi
fi

# Strip whitespace from credentials files to avoid authentication issues
TOKEN=$(cat "${FIREWATCH_JIRA_API_TOKEN_PATH}" | tr -d '[:space:]')
EMAIL=""
if [ -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
    EMAIL=$(cat "${FIREWATCH_JIRA_EMAIL_PATH}" | tr -d '[:space:]')
fi

# Build jira-config-gen command
if [ -n "${EMAIL}" ]; then
    echo "Using email + token authentication for Jira Cloud"
    firewatch jira-config-gen --token-path <(echo -n "${TOKEN}") --server-url "${FIREWATCH_JIRA_SERVER}" --email "${EMAIL}"
else
    echo "Using token-only authentication for Jira Server"
    firewatch jira-config-gen --token-path <(echo -n "${TOKEN}") --server-url "${FIREWATCH_JIRA_SERVER}"
fi

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

echo $report_command

eval "$report_command"
