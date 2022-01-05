#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted tools bump ocp command ************"

workdir=$(pwd)

cd /tmp/  # entering a writable dir

set +e
IS_REHEARSAL=$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

export DRY_RUN=""
if (( ${IS_REHEARSAL} )); then
    DRY_RUN="--dry-run"
fi

GITHUB_CREDS=$(cat ${CI_CREDENTIALS_DIR}/username <(echo ':') ${CI_CREDENTIALS_DIR}/github-access-token | tr -d "[:space:]") \
    ${workdir}/tools/bump_ocp_releases.py ${DRY_RUN}
