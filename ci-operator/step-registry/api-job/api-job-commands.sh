#!/bin/bash

set -e
set -u
set -o pipefail

prow_api_token=$(cat "/var/run/vault/tests-private-account/prow-api-token")
export APITOKEN=${prow_api_token}

github_token=$(cat "/var/run/vault/tests-private-account/token-git")
export GITHUB_TOKEN=${github_token}

which python3
python3 --version
job --version
job --help
# it runs the jobs from the https://github.com/openshift/release-tests/blob/master/_releases/required-jobs.json
job run_z_stream_test
