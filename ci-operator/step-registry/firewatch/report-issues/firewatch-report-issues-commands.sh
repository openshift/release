#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Firewatch Debug Info ==="
firewatch --version 2>&1 || echo "WARNING: firewatch --version not supported"
pip show firewatch 2>/dev/null | grep -E '^(Name|Version|Location)' || true
python3 -c "import firewatch; print('firewatch package path:', firewatch.__file__)" 2>/dev/null || true
echo "=== End Debug Info ==="

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

if [ -f /tmp/secrets/slack/slack_rule_notification_webhook_url ]; then
    SLACK_WEBHOOK_URL=$(cat /tmp/secrets/slack/slack_rule_notification_webhook_url)
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL%"${SLACK_WEBHOOK_URL##*[![:space:]]}"}"
    if [ -z "${SLACK_WEBHOOK_URL}" ]; then
        echo "ERROR: slack_rule_notification_webhook_url secret is present but empty" >&2
        exit 1
    fi
    export SLACK_WEBHOOK_URL
    echo "=== Slack Webhook ==="
    echo "SLACK_WEBHOOK_URL is set (${#SLACK_WEBHOOK_URL} chars, starts with: ${SLACK_WEBHOOK_URL:0:30}...)"
    echo "=== End Slack Webhook ==="
else
    echo "=== Slack Webhook ==="
    echo "WARNING: /tmp/secrets/slack/slack_rule_notification_webhook_url not found"
    ls -la /tmp/secrets/slack/ 2>/dev/null || echo "WARNING: /tmp/secrets/slack/ directory does not exist"
    echo "=== End Slack Webhook ==="
fi

echo "=== Report Command ==="
echo $report_command
echo "=== End Report Command ==="

eval "$report_command"
