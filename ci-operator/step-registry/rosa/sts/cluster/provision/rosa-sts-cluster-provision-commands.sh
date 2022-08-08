#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

subfix=$(openssl rand -hex 2)
CLUSTER_NAME=${CLUSTER_NAME:-"ci-rosa-s-$subfix"}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
MULTI_AZ=${MULTI_AZ:-false}
ENABLE_AUTOSCALING=${ENABLE_AUTOSCALING:-false}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
DISABLE_WORKLOAD_MONITORING=${DISABLE_WORKLOAD_MONITORING:-false}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}

ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")

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

# Init env
rosa init

# Check whether the cluster with the same cluster name existes.
OLD_CLUSTER=$(rosa list clusters | { grep  ${CLUSTER_NAME} || true; })
if [[ ! -z "$OLD_CLUSTER" ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  echo -e "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster: \n${OLD_CLUSTER}"
  exit 1
fi

# Get the ARN for each account role
echo -e "Validate the ARNs of the account roles with the prefix ${ACCOUNT_ROLES_PREFIX}"
Account_Installer_Role_Name="${ACCOUNT_ROLES_PREFIX}-Installer-Role"
Account_ControlPlane_Role_Name="${ACCOUNT_ROLES_PREFIX}-ControlPlane-Role"
Account_Support_Role_Name="${ACCOUNT_ROLES_PREFIX}-Support-Role"
Account_Worker_Role_Name="${ACCOUNT_ROLES_PREFIX}-Worker-Role"

roleARNList=$(rosa list account-roles -o json | jq -r '.[].RoleARN')

Account_Installer_Role_ARN=$(echo "$roleARNList" | { grep "${Account_Installer_Role_Name}" || true; })
Account_ControlPlane_Role_ARN=$(echo "$roleARNList" | { grep "${Account_ControlPlane_Role_Name}" || true; })
Account_Support_Role_ARN=$(echo "$roleARNList" | { grep "${Account_Support_Role_Name}" || true; })
Account_Worker_Role_ARN=$(echo "$roleARNList" | { grep "${Account_Worker_Role_Name}" || true; })
if [[ -z "${Account_ControlPlane_Role_ARN}" ]] || [[ -z "${Account_Installer_Role_ARN}" ]] || [[ -z "${Account_Support_Role_ARN}" ]] || [[ -z "${Account_Worker_Role_ARN}" ]]; then
  echo -e "One or more account roles with the prefix ${ACCOUNT_ROLES_PREFIX} do not exist"
  exit 1
fi

# Get the openshift version
versionList=$(rosa list versions --channel-group ${CHANNEL_GROUP} -o json | jq '.[].raw_id')
echo -e "Available cluster versions:\n${versionList}"
if [[ -z "$OPENSHIFT_VERSION" ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | head -1 | tr -d '"')
elif [[ $OPENSHIFT_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep "${OPENSHIFT_VERSION}" || true; } | head -1 | tr -d '"')
else
  # Match the whole line
  OPENSHIFT_VERSION=$(echo "$versionList" | { grep -x "\"${OPENSHIFT_VERSION}\"" || true; } | tr -d '"')
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi

if [[ "$CHANNEL_GROUP" != "stable" ]]; then
  OPENSHIFT_VERSION="${OPENSHIFT_VERSION}-${CHANNEL_GROUP}"
fi
echo "Choosing openshift version ${OPENSHIFT_VERSION}"

# Switches
MULTI_AZ_SWITCH=""
if [[ "$MULTI_AZ" == "true" ]]; then
  MULTI_AZ_SWITCH="--multi-az"
fi

COMPUTER_NODES_SWITCH=""
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  COMPUTER_NODES_SWITCH="--enable-autoscaling --min-replicas ${MIN_REPLICAS} --max-replicas ${MAX_REPLICAS}"
else
  COMPUTER_NODES_SWITCH="--compute-nodes ${COMPUTE_NODES}"
fi

ETCD_ENCRYPTION_SWITCH=""
if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
  ETCD_ENCRYPTION_SWITCH="--etcd-encryption"
fi

DISABLE_WORKLOAD_MONITORING_SWITCH=""
if [[ "$DISABLE_WORKLOAD_MONITORING" == "true" ]]; then
  DISABLE_WORKLOAD_MONITORING_SWITCH="--disable-workload-monitoring"
fi

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Account roles prefix: ${ACCOUNT_ROLES_PREFIX}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Disable workload monitoring: ${DISABLE_WORKLOAD_MONITORING}"
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  echo "  Enable autoscaling: ${ENABLE_AUTOSCALING}"
  echo "  Min replicas: ${MIN_REPLICAS}"
  echo "  Min replicas: ${MAX_REPLICAS}"  
else
  echo "  Cluster nodes: ${COMPUTE_NODES}"
fi

echo -e "
rosa create cluster --sts \
--mode auto \
-y \
--cluster-name ${CLUSTER_NAME} \
--role-arn ${Account_Installer_Role_ARN} \
--controlplane-iam-role ${Account_ControlPlane_Role_ARN} \
--support-role-arn ${Account_Support_Role_ARN} \
--worker-iam-role ${Account_Worker_Role_ARN} \
--region ${CLOUD_PROVIDER_REGION} \
--version ${OPENSHIFT_VERSION} \
--channel-group ${CHANNEL_GROUP} \
--compute-machine-type ${COMPUTE_MACHINE_TYPE} \
${MULTI_AZ_SWITCH} \
${COMPUTER_NODES_SWITCH} \
${ETCD_ENCRYPTION_SWITCH} \
${DISABLE_WORKLOAD_MONITORING_SWITCH}
"

mkdir -p "${SHARED_DIR}"
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"
CLUSTER_INFO="${ARTIFACT_DIR}/cluster.txt"
CLUSTER_INSTALL_LOG="${ARTIFACT_DIR}/.install.log"

rosa create cluster --sts \
                    --mode auto \
                    -y \
                    --cluster-name "${CLUSTER_NAME}" \
                    --role-arn "${Account_Installer_Role_ARN}" \
                    --controlplane-iam-role "${Account_ControlPlane_Role_ARN}" \
                    --support-role-arn "${Account_Support_Role_ARN}" \
                    --worker-iam-role "${Account_Worker_Role_ARN}" \
                    --region "${CLOUD_PROVIDER_REGION}" \
                    --version "${OPENSHIFT_VERSION}" \
                    --channel-group ${CHANNEL_GROUP} \
                    --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                    ${MULTI_AZ_SWITCH} \
                    ${COMPUTER_NODES_SWITCH} \
                    ${ETCD_ENCRYPTION_SWITCH} \
                    ${DISABLE_WORKLOAD_MONITORING_SWITCH} \
                    > "${CLUSTER_INFO}"

# Store the cluster ID for the post steps and the cluster deprovision
CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${CLUSTER_ID_FILE}"

echo "Waiting for cluster ready..."
start_time=$(date +"%s")
while true; do
  sleep 60
  CLUSTER_STATE=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.state')
  echo "Cluster state: ${CLUSTER_STATE}"
  if [[ "${CLUSTER_STATE}" == "ready" ]]; then
    echo "Cluster is reported as ready"
    break
  fi
  if (( $(date +"%s") - $start_time >= $CLUSTER_TIMEOUT )); then
    echo "error: Timed out while waiting for cluster to be ready"
    exit 1
  fi
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" && "${CLUSTER_STATE}" != "waiting" ]]; then
    rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done

# Print console.url and api.url
API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
CONSOLE_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.console.url')
echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"
