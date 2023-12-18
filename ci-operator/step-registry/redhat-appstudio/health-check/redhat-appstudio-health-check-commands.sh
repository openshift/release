#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_TOKEN
GITHUB_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github-token)

cd "$(mktemp -d)"
git clone --branch main https://github.com/redhat-appstudio/qe-tools .
make install

command=(qe-tools prowjob health-check --fail-if-unhealthy=false)

# flag "notify-on-pr" is valid only for "presubmit" type of job (which is triggered from a PR)
if [ "${JOB_TYPE:-}" = "presubmit" ]; then
    command+=(--notify-on-pr=true)
fi

"${command[@]}"