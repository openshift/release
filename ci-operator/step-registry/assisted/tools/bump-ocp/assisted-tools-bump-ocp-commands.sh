#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ assisted tools bump ocp command ************"

echo "This infrastructure is deprecated. Please refer to https://gitlab.cee.redhat.com/assisted-installer-ops/assisted-installer-cicd/-/tree/main/src/assisted_installer_cicd/bump_ocp_upstream"
exit 1

workdir=$(pwd)

cd /tmp/  # entering a writable dir

set +e
IS_REHEARSAL=$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

DRY_RUN_CMD=""
if (( ${IS_REHEARSAL} )) || [[ ${DRY_RUN} == "true" ]]; then
    DRY_RUN_CMD="--dry-run"
fi

GITHUB_CREDS=$(cat ${CI_CREDENTIALS_DIR}/username <(echo ':') ${CI_CREDENTIALS_DIR}/github-access-token | tr -d "[:space:]") \
    ${workdir}/tools/bump_ocp_releases.py ${DRY_RUN_CMD}
