#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ "${OPEN_NOTIFICATION}" == "no" ]]; then
  echo "Skip the notification step"
fi

function notify_ocmqe() {
  message=$1
  slack_message='{"text": "'"${message}"'. Sleep 8 hours for debugging with the job '"${JOB_NAME}/${BUILD_ID}"'. <@UD955LPJL> <@UEEQ10T4L>"}'
  if [[ -e ${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url ]]; then
    slack_hook_url=$(cat "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url")    
    curl -X POST -H 'Content-type: application/json' --data "${slack_message}" "${slack_hook_url}"
    sleep 28800
  fi
}

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
ROSA_VERSION=$(rosa version)
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

echo "Notify the error if the cluster in the unhealthy state."

# If cluster is in error state, call ocm-qe to analyze the root cause.
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.state')
if [[ "${CLUSTER_STATE}" == "error" ]]; then
  echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
  notify_ocmqe "Error: Cluster ${CLUSTER_ID} reported invalid state: ${CLUSTER_STATE}"
  exit 1
fi

# If api.url is null, call ocm-qe to analyze the root cause.
# For the api.url is manually spelled in the step rosa-cluster-provision, this issue is not consider as
# a blocker for testing.
API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
if [[ "${API_URL}" == "null" ]]; then
  echo "Warning: the api.url is null"
  notify_ocmqe "Warning: the api.url for the cluster ${CLUSTER_ID} is null"
  exit 0
fi
