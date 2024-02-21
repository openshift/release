#!/bin/bash

set -e
set -u
set -o pipefail

prow_api_token=$(cat "/var/run/vault/tests-private-account/prow-api-token")
export APITOKEN=$prow_api_token

github_token=$(cat "/var/run/vault/tests-private-account/token-git")
export GITHUB_TOKEN=$github_token

release_payload_modifier_token=$(cat /var/run/vault/release-payload-modifier-token)
export RELEASE_PAYLOAD_MODIFIER_TOKEN=$release_payload_modifier_token

python3 -V

#VALID_RELEASES="4.11 4.12 4.13 4.14 4.15 4.16"
VALID_RELEASES="4.16"
for release in $VALID_RELEASES
do
  echo "start job controller for $release"
  jobctl start-controller -r $release
  jobctl start-controller -r $release --no-nightly
done

jobctl start-aggregator

oc login api-ci-l2s4-p1-openshiftapps-com:8443 --token=$RELEASE_PAYLOAD_MODIFIER_TOKEN
oc get releasepayload/4.16.0-0.nightly-2024-02-03-221256 -n ocp
