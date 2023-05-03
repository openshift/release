#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

rm -rf   ${SHARED_DIR}/account-roles
mkdir    ${SHARED_DIR}/account-roles
tar xvfz ${SHARED_DIR}/account-roles.tar.gz -C ${SHARED_DIR}/account-roles
cd       ${SHARED_DIR}/account-roles

export HOME='/root' #pointing to location of .terraform.d

terraform init

terraform destroy -auto-approve

rm -rf ${SHARED_DIR}/account_roles
export HOME="${PWD}" # restore HOME
