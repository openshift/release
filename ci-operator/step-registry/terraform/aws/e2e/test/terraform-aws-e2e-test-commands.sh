#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi
TEST_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
TEST_TOKEN_URL="https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token"
TEST_GATEWAY_URL="https://api.stage.openshift.com"
TEST_OFFLINE_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
TEST_OPENSHIFT_VERSION="4.12"
printenv|sort
go version

mkdir -p ~/.aws
cp ${AWSCRED} ~/.aws/credentials
cp -r /root/terraform-provider-ocm ~/
cd ~/terraform-provider-ocm
export TEST_OFFLINE_TOKEN
export TEST_GATEWAY_URL
export TEST_TOKEN
export TEST_TOKEN_URL
export TEST_OPENSHIFT_VERSION

export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"

python3 ~/terraform-provider-ocm/scripts/run_make_e2e_test.py


