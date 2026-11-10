#!/bin/bash
set -euo pipefail

here=$(cd "$(dirname "$0")/../ci-operator/step-registry/redhat-developer/rhdh-plugin-export-overlays/ocp" && pwd)
e2e="${here}/e2e/redhat-developer-rhdh-plugin-export-overlays-ocp-e2e-commands.sh"
rc="${here}/helm/osl-rc/redhat-developer-rhdh-plugin-export-overlays-ocp-helm-osl-rc-commands.sh"
job=periodic-ci-redhat-developer-rhdh-plugin-export-overlays-main-e2e-ocp-helm-nightly
defaults=(
    MULTISTAGE_PARAM_OVERRIDE_GITHUB_ORG_NAME=
    MULTISTAGE_PARAM_OVERRIDE_GITHUB_REPOSITORY_NAME=
    MULTISTAGE_PARAM_OVERRIDE_RELEASE_BRANCH_NAME=
    MULTISTAGE_PARAM_OVERRIDE_GIT_PR_NUMBER=
    MULTISTAGE_PARAM_OVERRIDE_CATALOG_INDEX_IMAGE=
    MULTISTAGE_PARAM_OVERRIDE_PLAYWRIGHT_VERSION=
)

output=$(env "${defaults[@]}" JOB_TYPE=periodic JOB_NAME="$job" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc bash "$e2e" 2>&1)
[[ "$output" == *'Skipping standard E2E for OSL RC'* ]]
output=$(env "${defaults[@]}" JOB_TYPE=periodic JOB_NAME="${job/main/release-2.1}" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc bash "$e2e" 2>&1)
[[ "$output" == *'Skipping standard E2E for OSL RC'* ]]

if env "${defaults[@]}" JOB_TYPE=presubmit JOB_NAME="$job" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc bash "$e2e" >/dev/null 2>&1; then
    echo 'RC mode must reject non-periodic jobs' >&2
    exit 1
fi

if env "${defaults[@]}" JOB_TYPE=periodic JOB_NAME="${job/main/release-1.10}" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc bash "$e2e" >/dev/null 2>&1; then
    echo 'RC mode must reject nightlies without the RC step' >&2
    exit 1
fi

output=$(env JOB_TYPE=periodic JOB_NAME="$job" bash "$rc" 2>&1)
[[ "$output" == *'Skipping OSL RC for nightly run'* ]]

if env JOB_TYPE=periodic JOB_NAME="$job" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc bash "$rc" >/dev/null 2>&1; then
    echo 'RC mode must require a release manifest' >&2
    exit 1
fi

release_json='{"rhdhVersion":"2.1","ocpVersion":"4.20","logic":{"iib":"registry-proxy.engineering.redhat.com/rh-osbs/iib@sha256:0000000000000000000000000000000000000000000000000000000000000000","package":"logic-operator","channel":"stable-1.37","startingCSV":"logic-operator.v1.37.4","expectedVersion":"1.37.4"}}'
if output=$(env JOB_TYPE=periodic JOB_NAME="$job" MULTISTAGE_PARAM_OVERRIDE_OSL_MODE=rc MULTISTAGE_PARAM_OVERRIDE_OSL_RELEASE_JSON="$release_json" bash "$rc" 2>&1); then
    echo 'RC mode must require an overlays SHA before accessing credentials' >&2
    exit 1
fi
[[ "$output" == *'provide a 40-character overlays commit SHA'* ]]
