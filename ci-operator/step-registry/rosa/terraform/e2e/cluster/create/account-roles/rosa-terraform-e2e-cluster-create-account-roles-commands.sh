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

OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
export TF_VAR_token=${OCM_TOKEN}


rm -rf ${SHARED_DIR}/work
mkdir  ${SHARED_DIR}/work
if [[ -f ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz ]]; then
  tar xvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz -C ${SHARED_DIR}/work
fi
cd ${SHARED_DIR}/work

cp /root/terraform-provider-ocm/${TF_FOLDER}/* ./

rm terraform.tfvars || true
echo "${TF_VARS}"                                                    >> terraform.tfvars
echo "account_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""   >> terraform.tfvars
cat terraform.tfvars


# Check for provider source and version 'provider_source = "hashicorp/rhcs" (or "terraform.local/local/rhcs"') and 'provider_version = ">=1.0.1"'  
src=$(echo "${TF_VARS}" | grep 'provider_source'  | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
ver=$(echo "${TF_VARS}" | grep 'provider_version' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true

if [[ "$src" != "" && "$ver" != "" ]]; then
  provider=$(cat main.tf | awk '/required_providers/{line=1; next} line && /^\}/{exit} line' | awk '/rhcs(.+?)=(.+?)\{/{line=1; next} line && /\}/{exit} line')

  provider_src=$(echo "${provider}" | grep source  | awk -F '=' '{print $2}' | sed 's/[ |"]//g')
  sed -i "s|${provider_src}|source  = \"${src}\"|" main.tf
  provider_ver=$(echo "${provider}" | grep version | awk -F '=' '{print $2}' | sed 's/[ |"]//g')
  sed -i "s|${provider_ver}|version = \"${ver}\"|" main.tf
fi


HOME='/root' terraform init

trap 'tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*' TERM
set +o errexit #do the tar anyway

HOME='/root' terraform apply -auto-approve
tf_apply_rc=$?; echo "terraform apply rc=${tf_apply_rc}"

tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*  #save for later terraform destroy

set -o errexit