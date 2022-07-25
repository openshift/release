#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

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

# Log in
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi


CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

echo "Deleting cluster-id: ${CLUSTER_ID}"
rosa delete cluster -c "${CLUSTER_ID}" -y
while rosa describe cluster -c "${CLUSTER_ID}" ; do
  sleep 60
done

echo "Deleting operator roles"
rosa delete operator-roles -c "${CLUSTER_ID}" -y -m auto
echo "Deleting oidc-provider"
rosa delete oidc-provider -c "${CLUSTER_ID}" -y -m auto

echo "Cluster is no longer accessible; delete successful"
exit 0
