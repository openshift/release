#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Debug: Print credential paths and their existence
echo "=== Firewatch Jira Credentials Debug ==="
echo "FIREWATCH_JIRA_SERVER: ${FIREWATCH_JIRA_SERVER}"
echo "FIREWATCH_JIRA_API_TOKEN_PATH: ${FIREWATCH_JIRA_API_TOKEN_PATH}"
echo "FIREWATCH_JIRA_EMAIL_PATH: ${FIREWATCH_JIRA_EMAIL_PATH}"
echo ""
echo "Checking secrets directory /tmp/secrets/jira/:"
ls -la /tmp/secrets/jira/ || echo "Directory does not exist"
echo ""
echo "Token file exists: $([ -f "${FIREWATCH_JIRA_API_TOKEN_PATH}" ] && echo "YES" || echo "NO")"
echo "Email file exists: $([ -f "${FIREWATCH_JIRA_EMAIL_PATH}" ] && echo "YES" || echo "NO")"
echo ""
if [ -f "${FIREWATCH_JIRA_API_TOKEN_PATH}" ]; then
    echo "Token file size: $(wc -c < "${FIREWATCH_JIRA_API_TOKEN_PATH}") bytes"
    echo "Token file content (first 10 chars): $(head -c 10 "${FIREWATCH_JIRA_API_TOKEN_PATH}")..."
fi
if [ -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
    echo "Email file size: $(wc -c < "${FIREWATCH_JIRA_EMAIL_PATH}") bytes"
    echo "Email file content: $(cat "${FIREWATCH_JIRA_EMAIL_PATH}")"
fi
echo "========================================="
echo ""

# Jira Cloud (*.atlassian.net) requires email + API token authentication
# Jira Server only requires API token authentication
if [[ "${FIREWATCH_JIRA_SERVER}" == *"atlassian.net"* ]]; then
    if [ ! -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
        echo "ERROR: Jira Cloud requires email authentication. Please ensure FIREWATCH_JIRA_EMAIL_PATH is set and the email file exists at: ${FIREWATCH_JIRA_EMAIL_PATH}"
        exit 1
    fi
fi

jira_config_cmd="firewatch jira-config-gen --token-path ${FIREWATCH_JIRA_API_TOKEN_PATH} --server-url ${FIREWATCH_JIRA_SERVER}"

if [ -f "${FIREWATCH_JIRA_EMAIL_PATH}" ]; then
    jira_config_cmd+=" --email $(cat "${FIREWATCH_JIRA_EMAIL_PATH}")"
fi

eval "${jira_config_cmd}"

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
