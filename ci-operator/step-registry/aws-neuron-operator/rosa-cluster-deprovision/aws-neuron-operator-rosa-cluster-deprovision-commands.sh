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

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id" || true)
if [[ -z "$CLUSTER_ID" ]]; then
  CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-name" || true)
  if [[ -z "$CLUSTER_ID" ]]; then
    echo "No cluster is created. Softly exit the cluster deprovision."
    exit 0
  fi
fi

echo "Deleting cluster-id: ${CLUSTER_ID}"
start_time=$(date +"%s")
rosa delete cluster -c "${CLUSTER_ID}" -y
while true; do
  CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json 2>/dev/null | jq -r '.state' || true)
  echo "Cluster state: ${CLUSTER_STATE}"
  current_time=$(date +"%s")
  if (( current_time - start_time >= DESTROY_TIMEOUT )); then
    echo "error: Cluster not deleted after ${DESTROY_TIMEOUT}s"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" == "error" ]]; then
    echo "Cluster ${CLUSTER_ID} is on error state and wont be deleted."
    exit 1
  elif [[ "${CLUSTER_STATE}" == "" ]]; then
    echo "Cluster destroyed after $(( $(date +%s) - start_time )) seconds"
    break
  else
    echo "Cluster ${CLUSTER_ID} is on ${CLUSTER_STATE} state, waiting 60 seconds for the next check"
    sleep 60
  fi
done

# The OCM backend has a propagation delay: the cluster object disappears
# from "rosa describe" while the backend still considers it "uninstalling".
# Deleting operator-roles or the OIDC provider during this window fails with
# "Cluster is in 'uninstalling' state". A short wait before the first
# attempt plus retries handles this race reliably.
echo "Waiting ${STS_PROPAGATION_DELAY}s for cluster state to propagate..."
sleep "${STS_PROPAGATION_DELAY}"

sts_delete_with_retry() {
  local resource_type="$1"
  shift
  for attempt in $(seq 1 "${STS_DELETE_RETRIES}"); do
    echo "Deleting ${resource_type} (attempt ${attempt}/${STS_DELETE_RETRIES})"
    if rosa "$@" 2>&1; then
      echo "${resource_type} deleted successfully"
      return 0
    fi
    if [[ ${attempt} -lt ${STS_DELETE_RETRIES} ]]; then
      echo "${resource_type} deletion failed, retrying in ${STS_RETRY_INTERVAL}s..."
      sleep "${STS_RETRY_INTERVAL}"
    fi
  done
  echo "WARNING: ${resource_type} deletion failed after ${STS_DELETE_RETRIES} attempts"
  return 1
}

sts_delete_with_retry "operator-roles" delete operator-roles -c "${CLUSTER_ID}" -y -m auto || true
sts_delete_with_retry "oidc-provider" delete oidc-provider -c "${CLUSTER_ID}" -y -m auto || true

echo "Cluster is no longer accessible; delete successful."
exit 0
