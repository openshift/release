#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

ACCOUNT_ROLE_PREFIX=${ACCOUNT_ROLE_PREFIX:-$NAMESPACE}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
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

cp /terraform-provider-ocm/examples/create_rosa_cluster/create_rosa_sts_cluster/classic_sts/cluster/* ${SHARED_DIR}/terraform/cluster_sts/

pushd "${SHARED_DIR}/terraform/cluster_sts"

terraform init

cat <<_EOF > terraform.tfvars
url                    = "$OCM_URL"
token                  = "$OCM_TOKEN"
operator_role_prefix   = "$CLUSTER_NAME"
account_role_prefix    = "ManagedOpenShift"
cluster_name           = "$CLUSTER_NAME"
aws_region             = "$AWS_DEFAULT_REGION"
openshift_version      = "openshift-v$OPENSHIFT_VERSION"
_EOF

terraform apply -auto-approve

echo $(terraform output -json cluster_id| jq -r .) > cluster_id

pwd
ls -la
printenv|sort

popd
