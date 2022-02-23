#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools triage report command ************"

set +e
IS_REHEARSAL=$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

if (( ! ${IS_REHEARSAL} )) && [[ ${DRY_RUN} == "false" ]]; then
    export WEBHOOK
    WEBHOOK=$(cat ${CI_CREDENTIALS_DIR}/triage-webhook)
fi

JIRA_ACCESS_TOKEN=$(cat ${CI_CREDENTIALS_DIR}/jira-access-token) \
    ./tools/triage_status_report.py
