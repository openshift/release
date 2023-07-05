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
job get_payloads 4.11.0,4.12.0,4.13.0 --push true --run true
