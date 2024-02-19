#!/bin/bash

set -e
set -u
set -o pipefail

prow_api_token=$(cat "/var/run/vault/tests-private-account/prow-api-token")
export APITOKEN=${prow_api_token}

github_token=$(cat "/var/run/vault/tests-private-account/token-git")
export GITHUB_TOKEN=${github_token}

pip3 list
python3 -V
ls -l /usr/bin/python*
#VALID_RELEASES="4.11 4.12 4.13 4.14 4.15 4.16"
VALID_RELEASES="4.16"
for release in $VALID_RELEASES
do
  echo "start job controller for $release"
  jobctl start-controller -r $release
  jobctl start-controller -r $release --no-nightly
done

jobctl start-aggregator
