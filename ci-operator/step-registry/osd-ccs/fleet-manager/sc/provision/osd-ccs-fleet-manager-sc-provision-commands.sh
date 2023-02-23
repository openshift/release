#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "provision hello"

## Configure aws
#CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
#AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
#if [[ -f "${AWSCRED}" ]]; then
#  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
#  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
#else
#  echo "Did not find compatible cloud provider cluster_profile"
#  exit 1
#fi


# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/fleetmanager-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
