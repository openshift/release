#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Obtain aws credentials
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  AWS_ACCOUNT_ID=$(cat "${AWSCRED}" | grep aws_account_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials | jq -r .kubeconfig > "${SHARED_DIR}/kubeconfig"