#!/bin/bash
set -xeuo pipefail

DRY_RUN=""
if [[ "$JOB_NAME" == rehearse* ]]; then
    echo "INFO: \$JOB_NAME starts with rehearse - running in DRY RUN mode"
    DRY_RUN="-n"
fi

export PATH="${HOME}/.local/bin:${PATH}"

# Load the github credentials needed by the release notes script
APP_ID="$(cat /secrets/pr-creds/app_id)"
export APP_ID
export CLIENT_KEY=/secrets/pr-creds/key.pem

sleep 3600

cd /go/src/github.com/openshift/microshift/
./scripts/release-notes/gen_ec_release_notes.sh ${DRY_RUN}
