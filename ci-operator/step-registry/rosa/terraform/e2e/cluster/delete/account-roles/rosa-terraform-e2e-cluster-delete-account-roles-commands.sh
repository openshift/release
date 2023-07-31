#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ACCOUNT_ROLE_PREFIX=${ACCOUNT_ROLE_PREFIX:-$NAMESPACE}
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

TF_VAR_aws_access_key=$(cat ${CLUSTER_PROFILE_DIR}/.awscred | awk '/\[default\]/{line=1; next} line && /^\[/{exit} line' | grep aws_access_key_id     | awk -F '=' '{print $2}'| sed 's/ //g')
export TF_VAR_aws_access_key
TF_VAR_aws_secret_key=$(cat ${CLUSTER_PROFILE_DIR}/.awscred | awk '/\[default\]/{line=1; next} line && /^\[/{exit} line' | grep aws_secret_access_key | awk -F '=' '{print $2}'| sed 's/ //g')
export TF_VAR_aws_secret_key

OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
export TF_VAR_token=${OCM_TOKEN}

rm -rf ${SHARED_DIR}/work
mkdir  ${SHARED_DIR}/work
if [[ -f ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz ]]; then
  tar xvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz -C ${SHARED_DIR}/work
fi
cd ${SHARED_DIR}/work

HOME='/root' terraform init

HOME='/root' terraform destroy -auto-approve

rm -rf ${SHARED_DIR}/work ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz
