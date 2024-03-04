#!/bin/bash

set -e
set -u
set -o pipefail

prow_api_token=$(cat "/var/run/vault/tests-private-account/prow-api-token")
export APITOKEN=$prow_api_token

github_token=$(cat "/var/run/vault/tests-private-account/token-git")
export GITHUB_TOKEN=$github_token

release_payload_modifier_token=$(cat /var/run/vault/release-payload-modifier-token/token)
export RELEASE_PAYLOAD_MODIFIER_TOKEN=$release_payload_modifier_token

echo "Login cluster app.ci"
oc login api.ci.l2s4.p1.openshiftapps.com:6443 --token=$RELEASE_PAYLOAD_MODIFIER_TOKEN

echo -e "\n********* Start job controller *********\n"
#VALID_RELEASES="4.11 4.12 4.13 4.14 4.15 4.16"
VALID_RELEASES="4.16"
for release in $VALID_RELEASES
do
  echo -e "\nstart job controller for $release - $OCP_ARCH"
  jobctl start-controller -r $release --arch $OCP_ARCH
  jobctl start-controller -r $release --no-nightly --arch $OCP_ARCH
done

echo -e "\n********* Start test result aggregator - $OCP_ARCH *********\n"
jobctl start-aggregator --arch $OCP_ARCH
