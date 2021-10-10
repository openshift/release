#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools report command ************"

JIRA_USERNAME=$(cat /var/run/jira-credentials/username) \
    JIRA_PASSWORD=$(cat /var/run/jira-credentials/password) \
    WEBHOOK=$(cat /var/run/jira-credentials/webhook) \
    ./tools/triage_status_report.py
