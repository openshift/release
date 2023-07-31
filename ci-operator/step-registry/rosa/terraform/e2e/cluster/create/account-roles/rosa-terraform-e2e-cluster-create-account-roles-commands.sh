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

TF_FOLDER="ci/e2e/account_roles_files"

rm -rf ${SHARED_DIR}/work
mkdir  ${SHARED_DIR}/work
if [[ -f ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz ]]; then
  tar xvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz -C ${SHARED_DIR}/work
fi
cd ${SHARED_DIR}/work

cp /root/terraform-provider-rhcs/${TF_FOLDER}/* ./

rm terraform.tfvars || true
echo "${TF_VARS}"                                                    >> terraform.tfvars
echo "account_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""   >> terraform.tfvars
cat terraform.tfvars


# Check for provider source and version 'provider_source = "hashicorp/rhcs" (or "terraform.local/local/rhcs"') and 'provider_version = ">=1.0.1"'  
provider=$(cat main.tf | awk '/required_providers/{line=1; next} line && /^\}/{exit} line' | awk '/rhcs(\s+?)=(\s+?)\{/{line=1; next} line && /\}/{exit} line')

src=$(echo "${TF_VARS}" | grep provider_source | sed -rEz 's/.+?provider_source\s+?=\s+?(\"[^\"]*\").*/\1/')
if [[ "$src" != "" ]]; then
  provider_src=$(echo ${provider} | sed -rEz 's/.+?source\s+?=\s+?(\"[^\"]*\").*/\1/')
  sed -i "s|${provider_src}|${src}|" main.tf
fi

ver=$(echo "${TF_VARS}" | grep provider_version | sed -rEz 's/.+?provider_version\s+?=\s+?(\"[^\"]*\").*/\1/')
if [[ "$ver" != "" ]]; then
  provider_ver=$(echo ${provider} | sed -rEz 's/.+?version\s+?=\s+?(\"[^\"]*\").*/\1/')
  sed -i "s|${provider_ver}|${ver}|" main.tf
fi

cat main.tf

HOME='/root' terraform init

trap 'tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*' TERM
set +o errexit #do the tar anyway

HOME='/root' terraform apply -auto-approve
tf_apply_rc=$?; echo "terraform apply rc=${tf_apply_rc}"

tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*  #save for later terraform destroy

set -o errexit