#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

set_expiration_time() {
  local cluster_id="${1}"
  local expiration_time="${2}"
  echo "Set the expiration time '${expiration_time}' for the cluster with id '${cluster_id}'."
  # Properly format the time and then send the request via ocm patch
  expiration_time=$(date -u -d "${expiration_time}" "+%Y-%m-%dT%H:%M:%S.00000Z") && \
    echo "The expiration time was formatted to '${expiration_time}'." && \
    echo '{ "expiration_timestamp": "'"${expiration_time}"'" }' | ocm patch "/api/clusters_mgmt/v1/clusters/${cluster_id}"
}

handle_installation_failure() {
  local cluster_id="${1}"
  local installation_log
  # Print cluster status
  echo "Status for the cluster with id '${cluster_id}'."
  ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}" | jq -r '.status'
  # Archive installation log
  installation_log="${ARTIFACT_DIR}/.osd_install.log"
  echo "Archive installation log to '${installation_log}'."
  ocm get "/api/clusters_mgmt/v1/clusters/${cluster_id}/logs/install" > "${installation_log}" || echo "error: Unable to pull installation log."
  # Set expiration time if requested
  if [[ -n "${CLUSTER_DURATION_AFTER_FAILURE}" ]]; then
    echo "Set the expiration time after the failure."
    set_expiration_time "${cluster_id}" "+${CLUSTER_DURATION_AFTER_FAILURE}sec"
    echo "Delete the file '${HOME}/cluster-id' to avoid cluster deletion."
    rm -rf "${HOME}/cluster-id"
  fi
}

CLUSTER_NAME=${CLUSTER_NAME:-$NAMESPACE}
CLUSTER_VERSION=${CLUSTER_VERSION:-}
CLUSTER_MULTI_AZ=${CLUSTER_MULTI_AZ:-false}
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
OCM_CREATE_ARGS=""
if [[ -f "${AWSCRED}" ]]; then
  # Gather fields from the cluster_profile secret
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
  AWS_ACCOUNT_ID=$(cat "${CLUSTER_PROFILE_DIR}/aws-account-id")
  OCM_CREATE_ARGS="--aws-account-id ${AWS_ACCOUNT_ID} --aws-access-key-id ${AWS_ACCESS_KEY_ID} --aws-secret-access-key ${AWS_SECRET_ACCESS_KEY}"

  # Set defaults for AWS if necessary
  COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
  declare -a AWS_REGIONS=('us-east-1' 'us-east-2' 'us-west-1' 'us-west-2')
  RAND_REGION="${AWS_REGIONS[$RANDOM % ${#AWS_REGIONS[@]}]}"
  CLOUD_PROVIDER_REGION=${CLOUD_PROVIDER_REGION:-"${RAND_REGION}"}
  echo "Will launch in AWS region: ${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

export HOME=${SHARED_DIR}
mkdir -p "${HOME}"
if [[ ! -z "${SSO_CLIENT_ID}" && ! -z "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_URL} with SSO credentials"
  ocm login --url "${OCM_LOGIN_URL}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ ! -z "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_URL} with OCM token"
  ocm login --url "${OCM_LOGIN_URL}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to specify SSO_CLIENT_ID/SSO_CLIENT_SECRET or OCM_TOKEN!"
  exit 1
fi

versions=$(ocm list versions)
echo -e "Available cluster versions:\n${versions}"

if [[ $CLUSTER_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  CLUSTER_VERSION=$(echo "$versions" | grep ${CLUSTER_VERSION} | tail -1)
else
  # Match the whole line
  CLUSTER_VERSION=$(echo "$versions" | grep -x ${CLUSTER_VERSION})
fi

if [[ -z "$CLUSTER_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi

echo "Cluster version: $CLUSTER_VERSION"

OLD_CLUSTER_ID=$(ocm list clusters --columns=id --parameter search="name is '${CLUSTER_NAME}'" | tail -n 1)
if [[ "$OLD_CLUSTER_ID" != ID* ]]; then
  # A cluster id was returned; not just the ID column heading.
  # Previous cluster was orphaned somehow. Shut it down.
  echo "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster-id: ${OLD_CLUSTER_ID}"
  exit 1
fi

CLUSTER_INFO="${ARTIFACT_DIR}/ocm-cluster.txt"

CLUSTER_MULTI_AZ_SWITCH=""
if [[ "$CLUSTER_MULTI_AZ" == "true" ]]; then
  CLUSTER_MULTI_AZ_SWITCH="--multi-az"
fi

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Compute nodes: ${COMPUTE_NODES}"
echo "  Cluster version: ${CLUSTER_VERSION}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
echo "  Cluster multi-az: ${CLUSTER_MULTI_AZ}"
ocm create cluster ${OCM_CREATE_ARGS} \
                   --ccs "${CLUSTER_NAME}" \
                   --compute-nodes "${COMPUTE_NODES}" \
                   --version "${CLUSTER_VERSION}" \
                   --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                   --region "${CLOUD_PROVIDER_REGION}" \
                   ${CLUSTER_MULTI_AZ_SWITCH} \
                   > "${CLUSTER_INFO}"

CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"

# By default, OSD will setup clusters running for a few days before they expire.
# In case things go wrong in our flow, give the cluster an initial expiration
# that will minimize wasted compute if post steps are not successful.
# After installation, the expiration will be bumped according to CLUSTER_DURATION.
echo "Set the initial expiration time"
set_expiration_time "${CLUSTER_ID}" "+3hours"

# Store the cluster ID for the delete operation
echo -n "${CLUSTER_ID}" > "${HOME}/cluster-id"

echo "Waiting for cluster ready..."
start_time=$(date +"%s")
while true; do
  sleep 60
  CLUSTER_STATE=$(ocm get cluster "${CLUSTER_ID}" | jq -r '.status.state')
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster is reported as ready"
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster to be ready"
    handle_installation_failure "${CLUSTER_ID}"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" ]]; then
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    handle_installation_failure "${CLUSTER_ID}"
    exit 1
  fi
done

if [[ -n "${CLUSTER_DURATION}" ]]; then
  echo "Set the expiration time as set in CLUSTER_DURATION"
  set_expiration_time "${CLUSTER_ID}" "+${CLUSTER_DURATION}sec"
fi

ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.osd_install.log"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${SHARED_DIR}/kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" | jq -jr .admin.password > "${SHARED_DIR}/kubeadmin-password"
CONSOLE_URL=$(ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}" | jq -r .console.url)
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"

echo "Console URL: ${CONSOLE_URL}"
while true; do
  echo "Waiting for reachable api.."
  if oc --kubeconfig "${SHARED_DIR}/kubeconfig" get project/openshift-apiserver; then
    break
  fi
  sleep 30
done

# OSD replaces the provider selection template and eliminate the kube:admin option.
# Restore the ugly, but kube:admin containing, default template.
cd /tmp
oc --kubeconfig "${SHARED_DIR}/kubeconfig" patch oauth.config.openshift.io cluster --type='json' -p='{"spec":{"templates": null}}' --type=merge

exit 0
