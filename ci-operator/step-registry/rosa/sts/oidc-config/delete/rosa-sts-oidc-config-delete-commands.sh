#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

# If the oidc config exists, do deletion.
OIDC_CONFIG_FILE="${SHARED_DIR}/oidc-config"
if [[ -e "${OIDC_CONFIG_FILE}" ]]; then
  oidc_config_id=$(cat "${OIDC_CONFIG_FILE}" | jq -r '.id')

  echo "Start deleting the oidc config ${oidc_config_id}..."
  rosa delete oidc-provider -y --mode auto --oidc-config-id ${oidc_config_id} || true
  rosa delete oidc-config -y --mode auto --oidc-config-id ${oidc_config_id}
else
  echo "No oidc config created in the pre step"
fi
echo "Finish oidc config deletion."
