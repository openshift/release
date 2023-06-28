#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

prefix="ci-rosa-s"
if [[ "$HOSTED_CP" == "true" ]]; then
  prefix="ci-rosa-h"
fi
subfix=$(openssl rand -hex 2)
CLUSTER_NAME=${CLUSTER_NAME:-"$prefix-$subfix"}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
MULTI_AZ=${MULTI_AZ:-false}
EC2_METADATA_HTTP_TOKENS=${EC2_METADATA_HTTP_TOKENS:-optional}
ENABLE_AUTOSCALING=${ENABLE_AUTOSCALING:-false}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
DISABLE_WORKLOAD_MONITORING=${DISABLE_WORKLOAD_MONITORING:-false}
HOSTED_CP=${HOSTED_CP:-false}
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ ! -z "$REGION" ]]; then
  CLOUD_PROVIDER_REGION="${REGION}"
fi

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

# Check whether the cluster with the same cluster name existes.
OLD_CLUSTER=$(rosa list clusters | { grep  ${CLUSTER_NAME} || true; })
if [[ ! -z "$OLD_CLUSTER" ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  echo -e "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster: \n${OLD_CLUSTER}"
  exit 1
fi

# Get the openshift version
versionList=$(rosa list versions --channel-group ${CHANNEL_GROUP} -o json | jq -r '.[].raw_id')
if [[ "$HOSTED_CP" == "true" ]]; then
  versionList=$(rosa list versions --channel-group ${CHANNEL_GROUP} --hosted-cp -o json | jq -r '.[].raw_id')
fi
echo -e "Available cluster versions:\n${versionList}"

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  if [[ "$EC_BUILD" == "true" ]]; then
    OPENSHIFT_VERSION=$(echo "$versionList" | grep -i ec | head -1 || true)
  else
    OPENSHIFT_VERSION=$(echo "$versionList" | head -1)
  fi
elif [[ $OPENSHIFT_VERSION =~ ^[0-9]+\.[0-9]+$ ]]; then
  if [[ "$EC_BUILD" == "true" ]]; then
    OPENSHIFT_VERSION=$(echo "$versionList" | grep -E "^${OPENSHIFT_VERSION}" | grep -i ec | head -1 || true)
  else
    OPENSHIFT_VERSION=$(echo "$versionList" | grep -E "^${OPENSHIFT_VERSION}" | head -1 || true)
  fi
else
  # Match the whole line
  OPENSHIFT_VERSION=$(echo "$versionList" | grep -x "${OPENSHIFT_VERSION}" || true)
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi

# if [[ "$CHANNEL_GROUP" != "stable" ]]; then
#   OPENSHIFT_VERSION="${OPENSHIFT_VERSION}-${CHANNEL_GROUP}"
# fi
echo "Choosing openshift version ${OPENSHIFT_VERSION}"

# Switches
EC2_METADATA_HTTP_TOKENS_SWITCH=""
if [[ -n "${EC2_METADATA_HTTP_TOKENS}" && "$HOSTED_CP" != "true" ]]; then
  EC2_METADATA_HTTP_TOKENS_SWITCH="--ec2-metadata-http-tokens ${EC2_METADATA_HTTP_TOKENS}"
fi

MULTI_AZ_SWITCH=""
if [[ "$MULTI_AZ" == "true" ]]; then
  MULTI_AZ_SWITCH="--multi-az"
fi

COMPUTE_NODES_SWITCH=""
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  COMPUTE_NODES_SWITCH="--enable-autoscaling --min-replicas ${MIN_REPLICAS} --max-replicas ${MAX_REPLICAS}"
else
  COMPUTE_NODES_SWITCH="--replicas ${REPLICAS}"
fi

ETCD_ENCRYPTION_SWITCH=""
if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
  ETCD_ENCRYPTION_SWITCH="--etcd-encryption"
fi

DISABLE_WORKLOAD_MONITORING_SWITCH=""
if [[ "$DISABLE_WORKLOAD_MONITORING" == "true" ]]; then
  DISABLE_WORKLOAD_MONITORING_SWITCH="--disable-workload-monitoring"
fi

HYPERSHIFT_SWITCH=""
SUBNET_ID_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HYPERSHIFT_SWITCH="--hosted-cp --classic-oidc-config"
  if [[ "$ENABLE_SECTOR" == "true" ]]; then
    PROVISION_SHARD_ID=$(cat ${SHARED_DIR}/provision_shard_ids | head -n 1)
    if [[ -z "$PROVISION_SHARD_ID" ]]; then
      echo -e "No available provision shard."
      exit 1
    fi

    HYPERSHIFT_SWITCH="${HYPERSHIFT_SWITCH}  --properties provision_shard_id:${PROVISION_SHARD_ID}"
  fi  

  PUBLIC_SUBNET_IDs=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']")
  PRIVATE_SUBNET_IDs=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")
  if [[ -z "${PUBLIC_SUBNET_IDs}" ]] || [[ -z "${PRIVATE_SUBNET_IDs}" ]]; then
    echo -e "The public_subnet_ids and the the privated_subnet_ids are mandatory."
    exit 1
  fi
  SUBNET_ID_SWITCH="--subnet-ids ${PUBLIC_SUBNET_IDs},${PRIVATE_SUBNET_IDs}"
fi

FIPS_SWITCH=""
if [[ "$FIPS" == "true" ]]; then
  FIPS_SWITCH="--fips"
fi

PRIVATE_SWITCH=""
if [[ "$PRIVATE" == "true" ]]; then
  PRIVATE_SWITCH="--private"
fi

KMS_KEY_SWITCH=""
if [[ "$ENABLE_CUSTOMER_MANAGED_KEY" == "true" ]]; then
  # Get the kms keys from the previous steps, and replace the vaule here
  KMS_KEY_ARN=$(head -n 1 ${SHARED_DIR}/aws_kms_key_arn)
  KMS_KEY_SWITCH="--enable-customer-managed-key --kms-key-arn ${KMS_KEY_ARN}"
fi

PRIVATE_LINK_SWITCH=""
if [[ "$PRIVATE_LINK" == "true" ]]; then
  PRIVATE_LINK_SWITCH="--private-link"

  PRIVATE_SUBNET_IDs=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")
  if [[ -z "${PRIVATE_SUBNET_IDs}" ]]; then
    echo -e "The privated_subnet_ids are mandatory."
    exit 1
  fi
  SUBNET_ID_SWITCH="--subnet-ids ${PRIVATE_SUBNET_IDs}"
fi

PROXY_SWITCH=""
if [[ "$ENABLE_PROXY" == "true" ]]; then
  # Get the proxy information from the previous steps, and replace the vaule here
  proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")
  TRUST_BUNDLE_FILE="bundle_file"
  if [[ -z "${proxy_private_url}" ]] || [[ -z "${TRUST_BUNDLE_FILE}" ]]; then
    echo -e "The http_proxy, the http_proxy and the additional_trust_bundle_file are mandatory."
    exit 1
  fi
  PROXY_SWITCH="--http-proxy ${proxy_private_url} --https-proxy ${proxy_private_url} --additional-trust-bundle-file ${TRUST_BUNDLE_FILE}"
fi

DRY_RUN_SWITCH=""
if [[ "$DRY_RUN" == "true" ]]; then
  DRY_RUN_SWITCH="--dry-run"
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

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  Hypershift: ${HOSTED_CP}"
echo "  Account roles prefix: ${ACCOUNT_ROLES_PREFIX}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Fips: ${FIPS}"
echo "  Private: ${PRIVATE}"
echo "  Private Link: ${PRIVATE_LINK}"
echo "  Enable proxy: ${ENABLE_PROXY}"
echo "  Enable customer managed key: ${ENABLE_CUSTOMER_MANAGED_KEY}"
echo "  Enable ec2 metadata http tokens: ${EC2_METADATA_HTTP_TOKENS}"
echo "  Enable etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Disable workload monitoring: ${DISABLE_WORKLOAD_MONITORING}"
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  echo "  Enable autoscaling: ${ENABLE_AUTOSCALING}"
  echo "  Min replicas: ${MIN_REPLICAS}"
  echo "  Min replicas: ${MAX_REPLICAS}"  
else
  echo "  Replicas: ${REPLICAS}"
fi

echo -e "
rosa create cluster -y \
--mode auto \
--cluster-name ${CLUSTER_NAME} \
--role-arn ${Account_Installer_Role_ARN} \
--controlplane-iam-role ${Account_ControlPlane_Role_ARN} \
--support-role-arn ${Account_Support_Role_ARN} \
--worker-iam-role ${Account_Worker_Role_ARN} \
--region ${CLOUD_PROVIDER_REGION} \
--version ${OPENSHIFT_VERSION} \
--channel-group ${CHANNEL_GROUP} \
--compute-machine-type ${COMPUTE_MACHINE_TYPE} \
${EC2_METADATA_HTTP_TOKENS_SWITCH} \
${MULTI_AZ_SWITCH} \
${COMPUTE_NODES_SWITCH} \
${ETCD_ENCRYPTION_SWITCH} \
${DISABLE_WORKLOAD_MONITORING_SWITCH} \
${HYPERSHIFT_SWITCH} \
${SUBNET_ID_SWITCH} \
${FIPS_SWITCH} \
${KMS_KEY_SWITCH} \
${PRIVATE_SWITCH} \
${PRIVATE_LINK_SWITCH} \
${PROXY_SWITCH} \
${DRY_RUN_SWITCH}
"

mkdir -p "${SHARED_DIR}"
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"
CLUSTER_INFO="${ARTIFACT_DIR}/cluster.txt"
CLUSTER_INSTALL_LOG="${ARTIFACT_DIR}/.install.log"

# The default cluster mode is sts now
rosa create cluster -y \
                    --mode auto \
                    --cluster-name "${CLUSTER_NAME}" \
                    --role-arn "${Account_Installer_Role_ARN}" \
                    --controlplane-iam-role "${Account_ControlPlane_Role_ARN}" \
                    --support-role-arn "${Account_Support_Role_ARN}" \
                    --worker-iam-role "${Account_Worker_Role_ARN}" \
                    --region "${CLOUD_PROVIDER_REGION}" \
                    --version "${OPENSHIFT_VERSION}" \
                    --channel-group ${CHANNEL_GROUP} \
                    --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                    ${EC2_METADATA_HTTP_TOKENS_SWITCH} \
                    ${MULTI_AZ_SWITCH} \
                    ${COMPUTE_NODES_SWITCH} \
                    ${ETCD_ENCRYPTION_SWITCH} \
                    ${DISABLE_WORKLOAD_MONITORING_SWITCH} \
                    ${HYPERSHIFT_SWITCH} \
                    ${SUBNET_ID_SWITCH} \
                    ${FIPS_SWITCH} \
                    ${KMS_KEY_SWITCH} \
                    ${PRIVATE_SWITCH} \
                    ${PRIVATE_LINK_SWITCH} \
                    ${PROXY_SWITCH} \
                    ${DRY_RUN_SWITCH} \
                    > "${CLUSTER_INFO}"

# Store the cluster ID for the post steps and the cluster deprovision
CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${CLUSTER_ID_FILE}"

# Watch the hypershift install log
if [[ "$HOSTED_CP" == "true" ]]; then
  rosa logs install -c ${CLUSTER_ID} --watch
fi

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
  if [[ "${CLUSTER_STATE}" != "installing" && "${CLUSTER_STATE}" != "pending" && "${CLUSTER_STATE}" != "waiting" && "${CLUSTER_STATE}" != "validating" ]]; then
    rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}" || echo "error: Unable to pull installation log."
    echo "error: Cluster reported invalid state: ${CLUSTER_STATE}"
    exit 1
  fi
done
rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}"
rosa describe cluster -c ${CLUSTER_ID} -o json

# Print console.url and api.url
API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
CONSOLE_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.console.url')
echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"

PRODUCT_ID=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"
