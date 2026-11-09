#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

suffix=$(head /dev/urandom | tr -dc a-z0-9 | head -c 4)
CLUSTER_NAME=${CLUSTER_NAME:-"ci-osd-aws-$suffix"}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
MULTI_AZ=${MULTI_AZ:-false}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
DISABLE_WORKLOAD_MONITORING=${DISABLE_WORKLOAD_MONITORING:-false}
FIPS=${FIPS:-false}
REGION=${REGION:-"${LEASED_RESOURCE}"}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}

default_compute_nodes=2
if [[ "$MULTI_AZ" == "true" ]]; then
  default_compute_nodes=3
fi
COMPUTE_NODES=${COMPUTE_NODES:-$default_compute_nodes}

# Obtain aws credentials
if [[ -f "${CLUSTER_PROFILE_DIR}/osd-ccs-aws-credentials" ]]; then
  echo "Using OSD AWS CCS credentials (osdCcsAdmin) from the cluster profile"
  AWSCRED="${CLUSTER_PROFILE_DIR}/osd-ccs-aws-credentials"
else
  AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
fi
if [[ -f "${AWSCRED}" ]]; then
  AWS_ACCESS_KEY_ID=$(grep -m1 'aws_access_key_id' "${AWSCRED}" | tr -d ' ' | cut -d '=' -f2)
  AWS_SECRET_ACCESS_KEY=$(grep -m1 'aws_secret_access_key' "${AWSCRED}" | tr -d ' ' | cut -d '=' -f2)
  # Verify the credentials belong to the osdCcsAdmin IAM user before creating the cluster
  AWS_CALLER_ARN=$(AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}" aws sts get-caller-identity --query Arn --output text)
  AWS_ACCOUNT_ID=$(echo "${AWS_CALLER_ARN}" | cut -d ':' -f5)
  AWS_USER_NAME=$(echo "${AWS_CALLER_ARN}" | awk -F/ '{print $NF}')
  echo "AWS caller identity: ${AWS_CALLER_ARN}"
  if [[ "${AWS_USER_NAME}" != "osdCcsAdmin" ]]; then
    echo "error: OSD CCS clusters must be created with the osdCcsAdmin IAM user, got '${AWS_USER_NAME}'"
    exit 1
  fi
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

# Log in
read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

OCM_VERSION=$(ocm version)
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token using ocm cli ${OCM_VERSION}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token in the cluster profile!"
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
  OPENSHIFT_VERSION=$(echo "$versionList" | grep "^${OPENSHIFT_VERSION}" | tail -1 || true)
else
  # Match the whole line
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep -x "${OPENSHIFT_VERSION}" || true; })
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi
# OPENSHIFT_VERSION="openshift-v${OPENSHIFT_VERSION}"
echo "Select openshift version ${OPENSHIFT_VERSION}"

# Cluster parameters
echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Cloud provider region: aws"
echo "  Cloud provider region: ${REGION}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Compute nodes: ${COMPUTE_NODES}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Disable workload monitoring: ${DISABLE_WORKLOAD_MONITORING}"
echo "  Fips: ${FIPS}"

# Cluster payload
# Using the default aws credentials but not the user osdCcsAdmin's credentials to provision cluster
CLUSTER_PAYLOAD=$(echo -e '{
  "name": "'${CLUSTER_NAME}'",
  "region": {
    "id": "'${REGION}'"
  },
  "nodes": {
    "compute_machine_type": {
      "id": "'${COMPUTE_MACHINE_TYPE}'"
    },
    "compute": '${COMPUTE_NODES}'
  },
  "managed": true,
  "product": {
    "id": "osd"
  },
  "cloud_provider": {
    "id": "aws"
  },
  "multi_az": '${MULTI_AZ}',
  "etcd_encryption": '${ETCD_ENCRYPTION}',
  "disable_user_workload_monitoring": '${DISABLE_WORKLOAD_MONITORING}',
  "version": {
    "id": "openshift-v'${OPENSHIFT_VERSION}'",
    "channel_group": "'${CHANNEL_GROUP}'"
  },
  "properties": {
    "use_local_credentials": "true"
  },
  "ccs": {
    "enabled": true,
    "disable_scp_checks": false
  },
  "aws": {
    "access_key_id": "'${AWS_ACCESS_KEY_ID}'",
    "account_id": "'${AWS_ACCOUNT_ID}'",
    "secret_access_key": "'${AWS_SECRET_ACCESS_KEY}'"
  }
}')

if [[ "$FIPS" == "true" ]]; then
  CLUSTER_PAYLOAD=$(echo "${CLUSTER_PAYLOAD}" | jq '. +={"fips":true}')
fi

echo "${CLUSTER_PAYLOAD}" | jq -c | ocm post /api/clusters_mgmt/v1/clusters > "${ARTIFACT_DIR}/cluster.txt"

# Store the cluster ID for the post steps and the cluster deprovision
mkdir -p "${SHARED_DIR}"
CLUSTER_ID=$(cat "${ARTIFACT_DIR}/cluster.txt" | jq '.id' | tr -d '"')
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

echo "Waiting for cluster ready..."
start_time=$(date +"%s")
while true; do
  sleep 60
  CLUSTER_STATE=$(ocm get cluster "${CLUSTER_ID}" | jq -r '.status.state')
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster ${CLUSTER_ID} is reported as ready"
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster to be ready"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" ]]; then
    ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/logs/install" > "${ARTIFACT_DIR}/.cluster_install.log"
ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}"

# Print console.url
CONSOLE_URL=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.console.url')
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"

PRODUCT_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(ocm get /api/clusters_mgmt/v1/clusters/${CLUSTER_ID} | jq -r '.infra_id')
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
