#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# ACCOUNT_ROLE_PREFIX=${ACCOUNT_ROLE_PREFIX:-$NAMESPACE}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
CLUSTER_NAME=${CLUSTER_NAME:-ci-ocm-tf-$(mktemp -u XXXXX | tr '[:upper:]' '[:lower:]')}

# Configure aws
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
export TF_VAR_token=${OCM_TOKEN}

rm -rf ${SHARED_DIR}/work
mkdir  ${SHARED_DIR}/work
cd     ${SHARED_DIR}/work

if [[ -f ${SHARED_DIR}/${ART_NAME}.tar.gz ]]; then
  tar xvfz ${SHARED_DIR}/${ART_NAME}.tar.gz -C ${SHARED_DIR}/work
fi

cp     ${TF_FOLDER}/* ./

echo "cluster_name = \"${CLUSTER_NAME}\"" >> terraform.tfvars
export IFS=';'
for KV in ${TF_VARS}; do
  echo "${KV}" >> terraform.tfvars
done
cat terraform.tfvars

export HOME='/root' #pointing to location of .terraform.d

terraform init

terraform apply -auto-approve

tf_fldr="${TF_FOLDER##*/}"
if [[ "$(echo ${tf_fldr}|grep 'account_roles')"  == "" ]]; then
  terraform output -json cluster_id| jq -r . > ${SHARED_DIR}/ocm_cluster_id
fi

tar cvfz ${SHARED_DIR}/${ART_NAME}.tar.gz *.tf*  #save for later terraform destroy

rm -rf ${SHARED_DIR}/work
export HOME="${PWD}" #restore HOME

