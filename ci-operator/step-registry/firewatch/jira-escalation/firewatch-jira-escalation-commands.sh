#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Create the Jira configuration file
firewatch jira-config-gen --token-path "${FIREWATCH_JIRA_API_TOKEN_PATH}" --server-url "${FIREWATCH_JIRA_SERVER}"

escalation_command="firewatch jira-escalation"

sleep 3600


if [ -f "${FIREWATCH_DEFAULT_JIRA_PROJECT}" ]; then
    escalation_command+=" --default-jira-project=${FIREWATCH_DEFAULT_JIRA_PROJECT}"
fi

if [ -f "${SLACK_CHANNEL}" ]; then
    escalation_command+=" --slack-channel=${SLACK_CHANNEL}"
fi

if [ -f "${TEAM_MANAGER_EMAIL}" ]; then
    escalation_command+=" --team-manager-email=${TEAM_MANAGER_EMAIL}"
fi

if [ -f "${REPORTER_EMAIL}" ]; then
    escalation_command+=" --reporter-email=${REPORTER_EMAIL}"
fi


if [ -f "${FIREWATCH_JIRA_DEFAULT_LABELS}" ]; then
    escalation_command+=" --default-labels=${FIREWATCH_JIRA_DEFAULT_LABELS}"
fi

if [ -f "${SLACK_BOT_TOKEN}" ]; then
    escalation_command+=" --slack-bot-token=${SLACK_BOT_TOKEN}"
fi

if [ -f "${JIRA_CONFIG_PATH}" ]; then
    escalation_command+=" --jira-config-path=${JIRA_CONFIG_PATH}"
fi

if [ -f "${SLACK_TEAM_HANDLE}" ]; then
    escalation_command+=" --team-slack-handle=${SLACK_TEAM_HANDLE}"
fi


# If the additional labels file exists, add it to the report command
if [ -f "${FIREWATCH_JIRA_ADDITIONAL_LABELS}" ]; then
    escalation_command+=" --additional-labels=${FIREWATCH_JIRA_ADDITIONAL_LABELS}"
fi

echo $escalation_command

eval "$escalation_command"