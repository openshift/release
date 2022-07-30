#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

subfix=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
CLUSTER_NAME=${CLUSTER_NAME:-"ci-osd-ccs-$subfix"}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
MULTI_AZ=${MULTI_AZ:-false}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}

# Obtain aws credentials
AWSCRED="${SHARED_DIR}/osdCcsAdmin.awscred"
if [[ -f "${AWSCRED}" ]]; then
  AWS_ACCOUNT_ID=$(cat "${AWSCRED}" | grep aws_account_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)
  
  AWS_ARGS="--aws-account-id ${AWS_ACCOUNT_ID} --aws-access-key-id ${AWS_ACCESS_KEY_ID} --aws-secret-access-key ${AWS_SECRET_ACCESS_KEY}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
OCM_VERSION=$(ocm version)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
else
  echo "Cannot login! You need to specify the offline token OCM_TOKEN!"
  exit 1
fi

# Check whether the cluster with the same cluster name existes.
OLD_CLUSTER_ID=$(ocm list clusters --columns=id --parameter search="name is '${CLUSTER_NAME}'" | tail -n 1)
if [[ "$OLD_CLUSTER_ID" != ID* ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  echo "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster-id: ${OLD_CLUSTER_ID}"
  exit 1
fi

# Get the openshift version
versionList=$(ocm list versions --channel-group ${CHANNEL_GROUP})
echo -e "Available cluster versions:\n${versionList}"
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | tail -1)
elif [[ $OPENSHIFT_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep "${OPENSHIFT_VERSION}" || true; } | tail -1)
else
  # Match the whole line
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep -x "${OPENSHIFT_VERSION}" || true; })
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi
echo "Select openshift version ${OPENSHIFT_VERSION}"

# Switches
MULTI_AZ_SWITCH=""
if [[ "$MULTI_AZ" == "true" ]]; then
  MULTI_AZ_SWITCH="--multi-az"
fi

ETCD_ENCRYPTION_SWITCH=""
if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
  ETCD_ENCRYPTION_SWITCH="--etcd-encryption"
fi

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Cloud provider region: aws"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Cluster nodes: ${COMPUTE_NODES}"

mkdir -p "${SHARED_DIR}"
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"
CLUSTER_INFO="${ARTIFACT_DIR}/cluster.txt"
CLUSTER_INSTALL_LOG="${ARTIFACT_DIR}/.cluster_install.log"

ocm create cluster ${AWS_ARGS} \
                   --ccs "${CLUSTER_NAME}" \
                   --compute-nodes "${COMPUTE_NODES}" \
                   --version "${OPENSHIFT_VERSION}" \
                   --channel-group "${CHANNEL_GROUP}" \
                   --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                   --region "${CLOUD_PROVIDER_REGION}" \
                   ${MULTI_AZ_SWITCH} \
                   ${ETCD_ENCRYPTION_SWITCH} \
                   > "${CLUSTER_INFO}"

# Store the cluster ID for the post steps and the cluster deprovision
CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${CLUSTER_ID_FILE}"

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
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" ]]; then
    ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${CLUSTER_INSTALL_LOG}" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${CLUSTER_INSTALL_LOG}"

# Print console.url and api.url
CONSOLE_URL=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.console.url')
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
