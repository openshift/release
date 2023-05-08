#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "sleeping..."
sleep 3600

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


mkdir -p ~/.aws
cp ${AWSCRED} ~/.aws/credentials

TEST_OFFLINE_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
export TF_VAR_token=${TEST_OFFLINE_TOKEN}

export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"
export GOPROXY=https://proxy.golang.org
go mod download
go mod tidy
go mod vendor

make e2e_test