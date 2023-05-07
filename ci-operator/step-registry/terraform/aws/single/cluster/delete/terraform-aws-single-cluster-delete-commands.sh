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

rm -rf   ${SHARED_DIR}/work
mkdir    ${SHARED_DIR}/work
tar xvfz ${SHARED_DIR}/${ART_NAME}.tar.gz -C ${SHARED_DIR}/work
cd       ${SHARED_DIR}/work

export HOME='/root'  #pointing to location of .terraform.d

terraform init

terraform destroy -auto-approve

rm -rf   ${SHARED_DIR}/${ART_NAME}.tar.gz ${SHARED_DIR}/work
export HOME=${PWD} # restore HOME
