#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools ci report command ************"

set +e
IS_REHEARSAL=$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

if (( ! ${IS_REHEARSAL} )) && [[ ${DRY_RUN} == "false" ]]; then
    export SLACK_CHANNEL
    SLACK_CHANNEL=$(cat ${CI_CREDENTIALS_DIR}/ci-report-slack-channel)
fi

SLACK_AUTH_BEARER=$(cat ${CI_CREDENTIALS_DIR}/slack-auth-bearer) \
    ./tools/ci_status_report.py
