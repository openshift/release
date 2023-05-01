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

pwd
ls -la
printenv|sort

cat <<_EOF > terraform.tfvars
ocm_environment        = "$OCM_ENV"
openshift_version      = "openshift-v$OPENSHIFT_VERSION"
account_role_prefix    = "$ACCOUNT_ROLE_PREFIX"
token                  = "$OCM_TOKEN"
url                    = "$OCM_URL"
_EOF

terraform apply -auto-approve
