#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools report command ************"

export CI_CREDENTIALS_DIR=/var/run/assisted-installer-bot

JIRA_USERNAME=$(cat ${CI_CREDENTIALS_DIR}/username) \
    JIRA_PASSWORD=$(cat ${CI_CREDENTIALS_DIR}/password) \
    WEBHOOK=$(cat ${CI_CREDENTIALS_DIR}/triage-webhook) \
    ./tools/triage_status_report.py
