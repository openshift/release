#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export GITHUB_TOKEN QE_SPRAYPROXY_HOST QE_SPRAYPROXY_TOKEN

GITHUB_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/github-token)
QE_SPRAYPROXY_HOST=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-host)
QE_SPRAYPROXY_TOKEN=$(cat /usr/local/konflux-ci-secrets-new/redhat-appstudio-qe/qe-sprayproxy-token)

cd "$(mktemp -d)"
git clone --origin upstream --branch main "https://${GITHUB_TOKEN}@github.com/konflux-ci/e2e-tests.git" .

make ci/sprayproxy/unregister
