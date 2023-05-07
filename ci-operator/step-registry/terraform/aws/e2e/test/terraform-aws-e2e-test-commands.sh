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

printenv|sort
go version

mkdir -p ~/.aws
cp ${AWSCRED} ~/.aws/credentials

cp -r /terraform-provider-ocm ~/
cd ~/terraform-provider-ocm

export GOCACHE="/tmp/cache"
export GOMODCACHE="/tmp/cache"

go mod tidy
go mod vendor
make e2e_test
