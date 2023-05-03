#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ACCOUNT_ROLE_PREFIX=${ACCOUNT_ROLE_PREFIX:-$NAMESPACE}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
CLUSTER_NAME=${CLUSTER_NAME:-ci-ocm-tf-$(mktemp -u XXXXX | tr '[:upper:]' '[:lower:]')}
OCM_ENV=${OCM_ENV:-staging}


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

if [[ "${OCM_ENV}" == 'staging' ]]; then
  export OCM_URL='https://api.stage.openshift.com'
else
  export OCM_URL='https://api.openshift.com'
fi

rm -rf ${SHARED_DIR}/cluster_sts
mkdir  ${SHARED_DIR}/cluster_sts
cd     ${SHARED_DIR}/cluster_sts
cp /terraform-provider-ocm/ci/e2e/terraform_provider_ocm_files/* ./

cat <<_EOF > terraform.tfvars
url                    = "$OCM_URL"
token                  = "$OCM_TOKEN"
operator_role_prefix   = "$CLUSTER_NAME"
account_role_prefix    = "$ACCOUNT_ROLE_PREFIX"
cluster_name           = "$CLUSTER_NAME"
_EOF

export HOME='/root' #pointing to location of .terraform.d

terraform init

terraform apply -auto-approve

terraform output -json cluster_id| jq -r . > ${SHARED_DIR}/ocm_cluster_id

tar cvfz ${SHARED_DIR}/cluster_sts.tar.gz *.tf*  #save for later terraform destroy

rm -rf ${SHARED_DIR}/cluster_sts
export HOME="${PWD}" #restore HOME

