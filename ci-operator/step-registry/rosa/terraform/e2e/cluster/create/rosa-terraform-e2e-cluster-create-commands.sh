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

cp /root/terraform-provider-rhcs/${TF_FOLDER}/* ./

# Find openshift_version by channel_group in case openshift_version = "" 
ver=$(echo "${TF_VARS}" | grep 'openshift_version' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
if [[ "$ver" == "" ]]; then
  TF_VARS=$(echo "${TF_VARS}" | sed 's/openshift_version.*//')

  chn=$(echo "${TF_VARS}" | grep 'channel_group' | awk -F '=' '{print $2}' | sed 's/[ |"]//g') || true
  if [[ "$chn" == "" ]]; then
    chn='stable'
  fi

  ver=$(curl -kLs https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/$chn/release.txt | grep "Name\:" | awk '{print $NF}')
  TF_VARS+=$(echo -e "\nopenshift_version = \"$ver\"")
fi

rm terraform.tfvars || true
echo "${TF_VARS}"                                                    >> terraform.tfvars
echo "cluster_name = \"$(cat ${SHARED_DIR}/cluster-name)\""          >> terraform.tfvars
echo "account_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""   >> terraform.tfvars
echo "operator_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""  >> terraform.tfvars
cat terraform.tfvars


# Check for provider source and version 'provider_source = "hashicorp/rhcs" (or "terraform.local/local/rhcs"') and 'provider_version = ">=1.0.1"'  
provider=$(cat main.tf | awk '/required_providers/{line=1; next} line && /^\}/{exit} line' | awk '/rhcs(\s+?)=(\s+?)\{/{line=1; next} line && /\}/{exit} line')

src=$(echo "${TF_VARS}" | grep provider_source | sed -rEz 's/.+?provider_source\s+?=\s+?(\"[^\"]*\").*/\1/') || true
if [[ "$src" != "" ]]; then
  provider_src=$(echo ${provider} | sed -rEz 's/.+?source\s+?=\s+?(\"[^\"]*\").*/\1/')
  sed -i "s|${provider_src}|${src}|" main.tf
fi

ver=$(echo "${TF_VARS}" | grep provider_version | sed -rEz 's/.+?provider_version\s+?=\s+?(\"[^\"]*\").*/\1/') || true
if [[ "$ver" != "" ]]; then
  provider_ver=$(echo ${provider} | sed -rEz 's/.+?version\s+?=\s+?(\"[^\"]*\").*/\1/')
  sed -i "s|${provider_ver}|${ver}|" main.tf
fi


HOME='/root' terraform init

trap 'tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*' TERM
set +o errexit #to do the tar for the destroy

HOME='/root' terraform apply -auto-approve
tf_apply_rc=$?; echo "terraform apply rc=${tf_apply_rc}"

tar cvfz ${SHARED_DIR}/${TF_ARTIFACT_NAME}.tar.gz *.tf*  #save for later terraform destroy

if [ $tf_apply_rc -ne 0 ]; then
  exit $tf_apply_rc
fi  
set -o errexit

cluster_id=$(terraform output -json cluster_id | jq -r .)
echo ${cluster_id} > ${SHARED_DIR}/cluster-id

# get KUBECONFIG kubeadmin-assword
ocm login --token="${OCM_TOKEN}" --url="$(cat terraform.tfvars | grep 'url' | awk -F '=' '{print $2}' | sed 's/[ |"]//g')"
ocm get /api/clusters_mgmt/v1/clusters/${cluster_id}/credentials | jq -r .kubeconfig     > ${SHARED_DIR}/kubeconfig
ocm get /api/clusters_mgmt/v1/clusters/${cluster_id}/credentials | jq -r .admin.password > ${SHARED_DIR}/kubeadmin-password
cp ${SHARED_DIR}/kubeconfig ${ARTIFACT_DIR}/

export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc wait nodes --all --for=condition=Ready=true --timeout=30m &
oc wait clusteroperators --all --for=condition=Progressing=false --timeout=30m &
wait
