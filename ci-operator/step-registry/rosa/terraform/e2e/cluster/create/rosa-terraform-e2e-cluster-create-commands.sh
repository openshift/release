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
echo "cluster_name = \"$(cat ${SHARED_DIR}/cluster-name)\""          >> terraform.tfvars
echo "account_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""   >> terraform.tfvars
echo "operator_role_prefix = \"$(cat ${SHARED_DIR}/cluster-name)\""  >> terraform.tfvars
cat terraform.tfvars

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
ocm login --token=${OCM_TOKEN} --url=$(cat terraform.tfvars | grep 'url' | awk -F '=' '{print $2}' | sed 's/[ |"]//g')
ocm get /api/clusters_mgmt/v1/clusters/${cluster_id}/credentials | jq -r .kubeconfig     > ${SHARED_DIR}/kubeconfig
ocm get /api/clusters_mgmt/v1/clusters/${cluster_id}/credentials | jq -r .admin.password > ${SHARED_DIR}/kubeadmin-password
cp ${SHARED_DIR}/kubeconfig ${ARTIFACT_DIR}/

export KUBECONFIG=${SHARED_DIR}/kubeconfig
oc wait clusterversion version --for condition=Available --timeout=20m
