#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

cluster_id=$(head -n 1 "${SHARED_DIR}/cluster-id")

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
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
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token using rosa cli ${ROSA_VERSION}"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

upgraded_to_version=$(head -n 1 "${SHARED_DIR}/available_upgraded_to_version.txt")
if [[ -z "$upgraded_to_version" ]]; then
  echo "No available upgraded_to openshift version is found!"
  exit 1
fi

HCP_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HCP_SWITCH="--control-plane"
fi

# Get the cluster information before upgrading
rosa describe cluster -c $cluster_id
current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
if [[ "$current_version" == "$upgraded_to_version" ]]; then
  echo "The cluster has been in the version $upgraded_to_version"
  exit 1
fi

# Upgrade cluster
echo "Upgrade the cluster $cluster_id to $upgraded_to_version"
rosa upgrade cluster -y -m auto --version $upgraded_to_version -c $cluster_id ${HCP_SWITCH}
rosa describe upgrade cluster -c $cluster_id

start_time=$(date +"%s")
while true; do
  sleep 120
  echo "Wait for the cluster upgrading finished ..."
  current_version=$(rosa describe cluster -c $cluster_id -o json | jq -r '.openshift_version')
  if [[ "$current_version" == "$upgraded_to_version" ]]; then
    echo "Upgrade the cluster $cluster_id to the openshift version $upgraded_to_version successfully"
    break
  fi

  if (( $(date +"%s") - $start_time >= $CLUTER_UPGRADE_TIMEOUT )); then
    echo "error: Timed out while waiting for the cluster upgrading to be ready"
    set_proxy
    oc get clusteroperators
  fi
done
