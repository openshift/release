#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_TOKEN
GITHUB_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github-token)

cd "$(mktemp -d)"
git clone --branch main https://github.com/redhat-appstudio/qe-tools .
make build
./qe-tools prowjob health-check --notify-on-pr=true --fail-if-unhealthy=false