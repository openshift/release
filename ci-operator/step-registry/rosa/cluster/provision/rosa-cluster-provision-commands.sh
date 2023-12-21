#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

STS=${STS:-true}
HOSTED_CP=${HOSTED_CP:-false}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"m5.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
CHANNEL_GROUP=${CHANNEL_GROUP}
MULTI_AZ=${MULTI_AZ:-false}
EC2_METADATA_HTTP_TOKENS=${EC2_METADATA_HTTP_TOKENS:-"optional"}
ENABLE_AUTOSCALING=${ENABLE_AUTOSCALING:-false}
ETCD_ENCRYPTION=${ETCD_ENCRYPTION:-false}
STORAGE_ENCRYPTION=${STORAGE_ENCRYPTION:-false}
DISABLE_WORKLOAD_MONITORING=${DISABLE_WORKLOAD_MONITORING:-false}
DISABLE_SCP_CHECKS=${DISABLE_SCP_CHECKS:-false}
ENABLE_BYOVPC=${ENABLE_BYOVPC:-false}
ENABLE_PROXY=${ENABLE_PROXY:-false}
BYO_OIDC=${BYO_OIDC:-false}
ENABLE_AUDIT_LOG=${ENABLE_AUDIT_LOG:-false}
FIPS=${FIPS:-false}
PRIVATE=${PRIVATE:-false}
PRIVATE_LINK=${PRIVATE_LINK:-false}
PRIVATE_SUBNET_ONLY="false"
CLUSTER_TIMEOUT=${CLUSTER_TIMEOUT}
ENABLE_SHARED_VPC=${ENABLE_SHARED_VPC:-"no"}
ADDITIONAL_SECURITY_GROUP=${ADDITIONAL_SECURITY_GROUP:-false}

# Record Cluster Configurations
cluster_config_file="${SHARED_DIR}/cluster-config"
function record_cluster() {
  if [ $# -eq 2 ]; then
    location="."
    key=$1
    value=$2
  else
    location=".$1"
    key=$2
    value=$3
  fi

  payload=$(cat $cluster_config_file)
  if [[ "$value" == "true" ]] || [[ "$value" == "false" ]]; then
    echo $payload | jq "$location += {\"$key\":$value}" > $cluster_config_file
  else
    echo $payload | jq "$location += {\"$key\":\"$value\"}" > $cluster_config_file
  fi
}

# The rosa hypershift must be a STS cluster.
if [[ "$HOSTED_CP" == "true" ]]; then
  STS="true"
fi

# Define cluster name
if [[ ${ENABLE_SHARED_VPC} == "yes" ]] && [[ -e "${SHARED_DIR}/cluster-name" ]]; then
  # For Shared VPC cluster, cluster name is determined in step aws-provision-route53-private-hosted-zone
  #   as Private Hosted Zone needs to be ready before installing Shared VPC cluster
  CLUSTER_NAME=$(head -n 1 "${SHARED_DIR}/cluster-name")
else
  prefix="ci-rosa"
  if [[ "$HOSTED_CP" == "true" ]]; then
    prefix="ci-rosa-h"
  elif [[ "$STS" == "true" ]]; then
    prefix="ci-rosa-s"
  fi
  subfix=$(openssl rand -hex 2)
  CLUSTER_NAME=${CLUSTER_NAME:-"$prefix-$subfix"}
  echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"
fi

function notify_ocmqe() {
  message=$1
  slack_message='{"text": "'"${message}"'. Sleep 10 hours for debugging with the job '"${JOB_NAME}/${BUILD_ID}"'. <@UD955LPJL> <@UEEQ10T4L>"}'
  if [[ -e ${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url ]]; then
    slack_hook_url=$(cat "${CLUSTER_PROFILE_DIR}/ocm-slack-hooks-url")    
    curl -X POST -H 'Content-type: application/json' --data "${slack_message}" "${slack_hook_url}"
    sleep 36000
  fi
}

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

# Check whether the cluster with the same cluster name exists.
OLD_CLUSTER=$(rosa list clusters | { grep  ${CLUSTER_NAME} || true; })
if [[ ! -z "$OLD_CLUSTER" ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  echo -e "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster: \n${OLD_CLUSTER}"
  exit 1
fi

# Get the openshift version
if [[ ${AVAILABLE_UPGRADE} == "yes" ]] ; then
  OPENSHIFT_VERSION=$(head -n 1 "${SHARED_DIR}/available_upgrade_version.txt")
else
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
fi

if [[ -z "$OPENSHIFT_VERSION" ]]; then
  echo "Requested cluster version not available!"
  exit 1
fi

# if [[ "$CHANNEL_GROUP" != "stable" ]]; then
#   OPENSHIFT_VERSION="${OPENSHIFT_VERSION}-${CHANNEL_GROUP}"
# fi
echo "Choosing openshift version ${OPENSHIFT_VERSION}"

TAGS="prowci:${CLUSTER_NAME}"
if [[ ! -z "$CLUSTER_TAGS" ]]; then
  TAGS="${TAGS},${CLUSTER_TAGS}"
fi

cat > ${cluster_config_file} << EOF
{
  "name": "${CLUSTER_NAME}",
  "sts": ${STS},
  "hypershift": ${HOSTED_CP},
  "region": "${CLOUD_PROVIDER_REGION}",
  "version": {
    "channel_group": "${CHANNEL_GROUP}",
    "raw_id": "${OPENSHIFT_VERSION}"
  },
  "tags": "${TAGS}",
  "multi_az": ${MULTI_AZ},
  "disable_scp_checks": ${DISABLE_SCP_CHECKS},
  "disable_workload_monitoring": ${DISABLE_WORKLOAD_MONITORING},
  "etcd_encryption": ${ETCD_ENCRYPTION},
  "enable_customer_managed_key": ${STORAGE_ENCRYPTION},
  "fips": ${FIPS},
  "private": ${PRIVATE},
  "private_link": ${PRIVATE_LINK}
}
EOF

# Switches
MULTI_AZ_SWITCH=""
if [[ "$MULTI_AZ" == "true" ]]; then
  MULTI_AZ_SWITCH="--multi-az"
fi

DISABLE_SCP_CHECKS_SWITCH=""
if [[ "$DISABLE_SCP_CHECKS" == "true" ]]; then
  DISABLE_SCP_CHECKS_SWITCH="--disable-scp-checks"
fi

DISABLE_WORKLOAD_MONITORING_SWITCH=""
if [[ "$DISABLE_WORKLOAD_MONITORING" == "true" ]]; then
  DISABLE_WORKLOAD_MONITORING_SWITCH="--disable-workload-monitoring"
fi

DEFAULT_MP_LABELS_SWITCH=""
if [[ ! -z "$DEFAULT_MACHINE_POOL_LABELS" ]] && [[ "$HOSTED_CP" == "false" ]]; then
  DEFAULT_MP_LABELS_SWITCH="--default-mp-labels ${DEFAULT_MACHINE_POOL_LABELS}"
  record_cluster "default_mp_labels" ${DEFAULT_MACHINE_POOL_LABELS}
fi

EC2_METADATA_HTTP_TOKENS_SWITCH=""
if [[ -n "${EC2_METADATA_HTTP_TOKENS}" && "$HOSTED_CP" == "false" ]]; then
  EC2_METADATA_HTTP_TOKENS_SWITCH="--ec2-metadata-http-tokens ${EC2_METADATA_HTTP_TOKENS}"
  record_cluster "ec2_metadata_http_tokens" ${EC2_METADATA_HTTP_TOKENS}
fi

COMPUTER_NODE_ZONES_SWITCH=""
if [[ ! -z "$AVAILABILITY_ZONES" ]]; then
  AVAILABILITY_ZONES=$(echo $AVAILABILITY_ZONES | sed -E "s|(\w+)|${CLOUD_PROVIDER_REGION}&|g")
  COMPUTER_NODE_ZONES_SWITCH="--availability-zones ${AVAILABILITY_ZONES}"
  record_cluster "availability_zones" ${AVAILABILITY_ZONES}
fi

COMPUTER_NODE_DISK_SIZE_SWITCH=""
if [[ ! -z "$WORKER_DISK_SIZE" ]]; then
  COMPUTER_NODE_DISK_SIZE_SWITCH="--worker-disk-size ${WORKER_DISK_SIZE}"
  record_cluster "worker_disk_size" ${WORKER_DISK_SIZE}
fi

AUDIT_LOG_SWITCH=""
if [[ "$ENABLE_AUDIT_LOG" == "true" ]]; then
  iam_role_arn=$(head -n 1 ${SHARED_DIR}/iam_role_arn)
  AUDIT_LOG_SWITCH="--audit-log-arn $iam_role_arn"
  record_cluster "audit_log_arn" $iam_role_arn
fi

# If the node count is >=24 we enable autoscaling with max replicas set to the replica count so we can bypass the day2 rollout.
# This requires a second step in the waiting for nodes phase where we put the config back to the desired setup.
COMPUTE_NODES_SWITCH=""
if [[ ${REPLICAS} -ge 24 ]] && [[ "$HOSTED_CP" == "false" ]]; then
  MIN_REPLICAS=3
  MAX_REPLICAS=${REPLICAS}
  ENABLE_AUTOSCALING=true
fi
record_cluster "autoscaling" "enabled" ${ENABLE_AUTOSCALING}

if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then
  if [[ ${MIN_REPLICAS} -ge 24 ]] && [[ "$HOSTED_CP" == "false" ]]; then
    MIN_REPLICAS=3
  fi
  COMPUTE_NODES_SWITCH="--enable-autoscaling --min-replicas ${MIN_REPLICAS} --max-replicas ${MAX_REPLICAS}"  
  record_cluster "nodes" "max_replicas" ${MIN_REPLICAS}
  record_cluster "nodes" "min_replicas" ${MAX_REPLICAS}
else
  COMPUTE_NODES_SWITCH="--replicas ${REPLICAS}"
  record_cluster "nodes" "replicas" ${REPLICAS}
fi

ETCD_ENCRYPTION_SWITCH=""
if [[ "$ETCD_ENCRYPTION" == "true" ]]; then
  ETCD_ENCRYPTION_SWITCH="--etcd-encryption"
  if [[ "$HOSTED_CP" == "true" ]]; then
    kms_key_arn=$(cat <${SHARED_DIR}/aws_kms_key_arn)
    ETCD_ENCRYPTION_SWITCH="${ETCD_ENCRYPTION_SWITCH} --etcd-encryption-kms-arn $kms_key_arn"
    record_cluster "encryption" "etcd_encryption_kms_arn" $kms_key_arn
  fi
fi

STORAGE_ENCRYPTION_SWITCH=""
if [[ "$STORAGE_ENCRYPTION" == "true" ]]; then
  kms_key_arn=$(cat <${SHARED_DIR}/aws_kms_key_arn)
  STORAGE_ENCRYPTION_SWITCH="--enable-customer-managed-key --kms-key-arn $kms_key_arn"
  record_cluster "encryption" "kms_key_arn" $kms_key_arn
fi

HYPERSHIFT_SWITCH=""
if [[ "$HOSTED_CP" == "true" ]]; then
  HYPERSHIFT_SWITCH="--hosted-cp"
  if [[ "$ENABLE_SECTOR" == "true" ]]; then
    PROVISION_SHARD_ID=$(cat ${SHARED_DIR}/provision_shard_ids | head -n 1)
    if [[ -z "$PROVISION_SHARD_ID" ]]; then
      echo -e "No available provision shard."
      exit 1
    fi

    HYPERSHIFT_SWITCH="${HYPERSHIFT_SWITCH}  --properties provision_shard_id:${PROVISION_SHARD_ID}"
    record_cluster "properties" "provision_shard_id" ${PROVISION_SHARD_ID}
  fi

  ENABLE_BYOVPC="true"
  BYO_OIDC="true"
fi

FIPS_SWITCH=""
if [[ "$FIPS" == "true" ]]; then
  FIPS_SWITCH="--fips"
fi

PRIVATE_SWITCH=""
if [[ "$PRIVATE" == "true" ]]; then
  PRIVATE_SWITCH="--private"
fi

PRIVATE_LINK_SWITCH=""
if [[ "$PRIVATE_LINK" == "true" ]]; then
  PRIVATE_LINK_SWITCH="--private-link"

  ENABLE_BYOVPC="true"
  PRIVATE_SUBNET_ONLY="true"
fi

PROXY_SWITCH=""
if [[ "$ENABLE_PROXY" == "true" ]]; then
  # In step aws-provision-bastionhos, the values for proxy_private_url and proxy_public_url are same
  proxy_private_url=$(< "${SHARED_DIR}/proxy_private_url")
  if [[ -z "${proxy_private_url}" ]]; then
    echo -e "The http_proxy, and https_proxy URLs are mandatory when specifying use of proxy."
    exit 1
  fi
  PROXY_SWITCH="--http-proxy ${proxy_private_url} --https-proxy ${proxy_private_url}"

  trust_bundle_file="${SHARED_DIR}/bundle_file"
  if [[ -f "${trust_bundle_file}" ]]; then
    echo -e "Using proxy with requested additional trust bundle"
    PROXY_SWITCH="${PROXY_SWITCH} --additional-trust-bundle-file ${trust_bundle_file}"
  fi
  ENABLE_BYOVPC="true"

  record_cluster "proxy" "enabled" ${ENABLE_PROXY}
  record_cluster "proxy" "http" $proxy_private_url
  record_cluster "proxy" "https" $proxy_private_url
  record_cluster "proxy" "trust_bundle_file" $trust_bundle_file  
fi

SUBNET_ID_SWITCH=""
if [[ "$ENABLE_BYOVPC" == "true" ]]; then
  PUBLIC_SUBNET_IDs=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']")
  PRIVATE_SUBNET_IDs=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")
  if [[ -z "${PRIVATE_SUBNET_IDs}" ]]; then
    echo -e "The private_subnet_ids are mandatory."
    exit 1
  fi
  
  if [[ "${PRIVATE_SUBNET_ONLY}" == "true" ]] ; then
    SUBNET_ID_SWITCH="--subnet-ids ${PRIVATE_SUBNET_IDs}"
    record_cluster "subnets" "private_subnet_ids" ${PRIVATE_SUBNET_IDs}
  else
    if [[ -z "${PUBLIC_SUBNET_IDs}" ]] ; then
      echo -e "The public_subnet_ids are mandatory."
      exit 1
    fi
    SUBNET_ID_SWITCH="--subnet-ids ${PUBLIC_SUBNET_IDs},${PRIVATE_SUBNET_IDs}"
    record_cluster "subnets" "private_subnet_ids" ${PRIVATE_SUBNET_IDs}
    record_cluster "subnets" "public_subnet_ids" ${PUBLIC_SUBNET_IDs}
  fi
fi
# Additional security groups options
SECURITY_GROUP_ID_SWITCH=""
if [[ "$ADDITIONAL_SECURITY_GROUP" == "true" ]]; then
  SECURITY_GROUP_IDs=$(cat ${SHARED_DIR}/security_groups_ids | xargs |sed 's/ /,/g')
  SECURITY_GROUP_ID_SWITCH="--additional-compute-security-group-ids ${SECURITY_GROUP_IDs}"
  record_cluster "security_groups" "enabled" ${SECURITY_GROUP_IDs}
fi

# STS options
STS_SWITCH="--non-sts"
ACCOUNT_ROLES_SWITCH=""
BYO_OIDC_SWITCH=""
if [[ "$STS" == "true" ]]; then
  STS_SWITCH="--sts"

  # Account roles
  ACCOUNT_ROLES_PREFIX=$(cat "${SHARED_DIR}/account-roles-prefix")
  echo -e "Get the ARNs of the account roles with the prefix ${ACCOUNT_ROLES_PREFIX}"

  roleARNFile="${SHARED_DIR}/account-roles-arns"
  account_intaller_role_arn=$(cat "$roleARNFile" | { grep "Installer-Role" || true; })
  account_support_role_arn=$(cat "$roleARNFile" | { grep "Support-Role" || true; })
  account_worker_role_arn=$(cat "$roleARNFile" | { grep "Worker-Role" || true; })
  if [[ -z "${account_intaller_role_arn}" ]] || [[ -z "${account_support_role_arn}" ]] || [[ -z "${account_worker_role_arn}" ]]; then
    echo -e "One or more account roles with the prefix ${ACCOUNT_ROLES_PREFIX} do not exist"
    exit 1
  fi  
  ACCOUNT_ROLES_SWITCH="--role-arn ${account_intaller_role_arn} --support-role-arn ${account_support_role_arn} --worker-iam-role ${account_worker_role_arn}"
  record_cluster "aws.sts" "role_arn" $account_intaller_role_arn
  record_cluster "aws.sts" "support_role_arn" $account_support_role_arn
  record_cluster "aws.sts" "worker_role_arn" $account_worker_role_arn

  if [[ "$HOSTED_CP" == "false" ]]; then
    account_control_plane_role_arn=$(cat "$roleARNFile" | { grep "ControlPlane-Role" || true; })
    if [[ -z "${account_control_plane_role_arn}" ]]; then
      echo -e "The control plane account role with the prefix ${ACCOUNT_ROLES_PREFIX} do not exist"
      exit 1
    fi      
    ACCOUNT_ROLES_SWITCH="${ACCOUNT_ROLES_SWITCH} --controlplane-iam-role ${account_control_plane_role_arn}"
    record_cluster "aws.sts" "control_plane_role_arn" $account_control_plane_role_arn
  fi

  if [[ "$BYO_OIDC" == "true" ]]; then
    oidc_config_id=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')
    operator_roles_prefix=$(cat "${SHARED_DIR}/operator-roles-prefix")
    BYO_OIDC_SWITCH="--oidc-config-id ${oidc_config_id} --operator-roles-prefix ${operator_roles_prefix}"
    record_cluster "aws.sts" "oidc_config_id" $oidc_config_id
    record_cluster "aws.sts" "operator_roles_prefix" $operator_roles_prefix
  fi
fi

SHARED_VPC_SWITCH=""
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  SAHRED_VPC_HOSTED_ZONE_ID=$(head -n 1 "${SHARED_DIR}/hosted_zone_id")
  SAHRED_VPC_ROLE_ARN=$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")
  SAHRED_VPC_BASE_DOMAIN=$(head -n 1 "${SHARED_DIR}/rosa_dns_domain")

  SHARED_VPC_SWITCH=" --private-hosted-zone-id ${SAHRED_VPC_HOSTED_ZONE_ID} "
  SHARED_VPC_SWITCH+=" --shared-vpc-role-arn ${SAHRED_VPC_ROLE_ARN} "
  SHARED_VPC_SWITCH+=" --base-domain ${SAHRED_VPC_BASE_DOMAIN} "

  record_cluster "aws.sts" "private_hosted_zone_id" ${SAHRED_VPC_HOSTED_ZONE_ID}
  record_cluster "aws.sts" "private_hosted_zone_role_arn" ${SAHRED_VPC_ROLE_ARN}
  record_cluster "dns" "base_domain" ${SAHRED_VPC_BASE_DOMAIN}

  # update shared-role policy for Shared-VPC cluster
  #
  if [[ ! -e "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
    echo "No Shared VPC account found. Exit now."
    exit 1
  fi

  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  installer_role_arn=$(grep "Installer-Role" "${SHARED_DIR}/account-roles-arns")
  ingress_role_arn=$(grep "ingress-operator" "${SHARED_DIR}/operator-roles-arns")
  shared_vpc_updated_trust_policy=$(mktemp)
  cat > $shared_vpc_updated_trust_policy <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "AWS": [
                "${installer_role_arn}",
                "${ingress_role_arn}"
              ]
          },
          "Action": "sts:AssumeRole",
          "Condition": {}
      }
  ]
}
EOF
  aws iam update-assume-role-policy --role-name "$(echo ${SAHRED_VPC_ROLE_ARN} | cut -d '/' -f2)"  --policy-document file://${shared_vpc_updated_trust_policy}
  echo "Updated Shared VPC role trust policy:"
  cat $shared_vpc_updated_trust_policy
  
  echo "Sleeping 120s to make sure the policy is ready."
  sleep 120

  echo "Change AWS profile back to cluster owner"
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
fi

DRY_RUN_SWITCH=""
if [[ "$DRY_RUN" == "true" ]]; then
  DRY_RUN_SWITCH="--dry-run"
fi

# Save the cluster config to ARTIFACT_DIR
cp "${SHARED_DIR}/cluster-config" "${ARTIFACT_DIR}/"

echo "Parameters for cluster request:"
echo "  Cluster name: ${CLUSTER_NAME}"
echo "  STS mode: ${STS}"
echo "  Hypershift: ${HOSTED_CP}"
echo "  Byo OIDC: ${BYO_OIDC}"
echo "  Compute machine type: ${COMPUTE_MACHINE_TYPE}"
echo "  Worker disk size: ${WORKER_DISK_SIZE}"
echo "  Cloud provider region: ${CLOUD_PROVIDER_REGION}"
echo "  Multi-az: ${MULTI_AZ}"
echo "  Openshift version: ${OPENSHIFT_VERSION}"
echo "  Channel group: ${CHANNEL_GROUP}"
echo "  Fips: ${FIPS}"
echo "  Private: ${PRIVATE}"
echo "  Private Link: ${PRIVATE_LINK}"
echo "  Enable proxy: ${ENABLE_PROXY}"
echo "  Enable customer managed key: ${STORAGE_ENCRYPTION}"
echo "  Enable ec2 metadata http tokens: ${EC2_METADATA_HTTP_TOKENS}"
echo "  Enable etcd encryption: ${ETCD_ENCRYPTION}"
echo "  Disable workload monitoring: ${DISABLE_WORKLOAD_MONITORING}"
echo "  Enable Byovpc: ${ENABLE_BYOVPC}"
echo "  Enable audit log: ${ENABLE_AUDIT_LOG}"
echo "  Cluster Tags: ${TAGS}"
echo "  Additional Security groups: ${ADDITIONAL_SECURITY_GROUP}"
echo "  Enable autoscaling: ${ENABLE_AUTOSCALING}"
if [[ "$ENABLE_AUTOSCALING" == "true" ]]; then 
  echo "  Min replicas: ${MIN_REPLICAS}"
  echo "  Min replicas: ${MAX_REPLICAS}"  
else
  echo "  Replicas: ${REPLICAS}"
fi

echo "  Enable Shared VPC: ${ENABLE_SHARED_VPC}"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  echo "    SAHRED_VPC_HOSTED_ZONE_ID: ${SAHRED_VPC_HOSTED_ZONE_ID}"
  echo "    SAHRED_VPC_ROLE_ARN: ${SAHRED_VPC_ROLE_ARN}"
  echo "    SAHRED_VPC_BASE_DOMAIN: ${SAHRED_VPC_BASE_DOMAIN}"
fi

echo -e "
rosa create cluster -y \
${STS_SWITCH} \
--mode auto \
--cluster-name ${CLUSTER_NAME} \
--region ${CLOUD_PROVIDER_REGION} \
--version ${OPENSHIFT_VERSION} \
--channel-group ${CHANNEL_GROUP} \
--compute-machine-type ${COMPUTE_MACHINE_TYPE} \
--tags ${TAGS} \
${ACCOUNT_ROLES_SWITCH} \
${EC2_METADATA_HTTP_TOKENS_SWITCH} \
${MULTI_AZ_SWITCH} \
${COMPUTE_NODES_SWITCH} \
${BYO_OIDC_SWITCH} \
${ETCD_ENCRYPTION_SWITCH} \
${DISABLE_WORKLOAD_MONITORING_SWITCH} \
${HYPERSHIFT_SWITCH} \
${SUBNET_ID_SWITCH} \
${FIPS_SWITCH} \
${PRIVATE_SWITCH} \
${PRIVATE_LINK_SWITCH} \
${PROXY_SWITCH} \
${DISABLE_SCP_CHECKS_SWITCH} \
${DEFAULT_MP_LABELS_SWITCH} \
${STORAGE_ENCRYPTION_SWITCH} \
${AUDIT_LOG_SWITCH} \
${COMPUTER_NODE_ZONES_SWITCH} \
${COMPUTER_NODE_DISK_SIZE_SWITCH} \
${SHARED_VPC_SWITCH} \
${SECURITY_GROUP_ID_SWITCH} \
${DRY_RUN_SWITCH}
" | sed -E 's/\s{2,}/ /g' > "${ARTIFACT_DIR}/create_cluster.sh"

mkdir -p "${SHARED_DIR}"
CLUSTER_ID_FILE="${SHARED_DIR}/cluster-id"
CLUSTER_INFO="${ARTIFACT_DIR}/cluster.txt"
CLUSTER_INSTALL_LOG="${ARTIFACT_DIR}/.install.log"

# The default cluster mode is sts now
rosa create cluster -y \
                    ${STS_SWITCH} \
                    ${HYPERSHIFT_SWITCH} \
                    --mode auto \
                    --cluster-name "${CLUSTER_NAME}" \
                    --region "${CLOUD_PROVIDER_REGION}" \
                    --version "${OPENSHIFT_VERSION}" \
                    --channel-group "${CHANNEL_GROUP}" \
                    --compute-machine-type "${COMPUTE_MACHINE_TYPE}" \
                    --tags "${TAGS}" \
                    ${ACCOUNT_ROLES_SWITCH} \
                    ${EC2_METADATA_HTTP_TOKENS_SWITCH} \
                    ${MULTI_AZ_SWITCH} \
                    ${COMPUTE_NODES_SWITCH} \
                    ${BYO_OIDC_SWITCH} \
                    ${ETCD_ENCRYPTION_SWITCH} \
                    ${DISABLE_WORKLOAD_MONITORING_SWITCH} \
                    ${SUBNET_ID_SWITCH} \
                    ${FIPS_SWITCH} \
                    ${PRIVATE_SWITCH} \
                    ${PRIVATE_LINK_SWITCH} \
                    ${PROXY_SWITCH} \
                    ${DISABLE_SCP_CHECKS_SWITCH} \
                    ${DEFAULT_MP_LABELS_SWITCH} \
                    ${STORAGE_ENCRYPTION_SWITCH} \
                    ${AUDIT_LOG_SWITCH} \
                    ${COMPUTER_NODE_ZONES_SWITCH} \
                    ${COMPUTER_NODE_DISK_SIZE_SWITCH} \
                    ${SHARED_VPC_SWITCH} \
                    ${SECURITY_GROUP_ID_SWITCH} \
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

    # If the cluster is in error state, notify the ocm qes for debugging.
    if [[ "${CLUSTER_STATE}" == "error" ]]; then
      current_time=$(date -u '+%H')
      if [ $current_time -lt 10 ]; then
        notify_ocmqe "Error: Cluster ${CLUSTER_ID} reported invalid state: ${CLUSTER_STATE}"
      fi
    fi
    exit 1
  fi
done
rosa logs install -c ${CLUSTER_ID} > "${CLUSTER_INSTALL_LOG}"
rosa describe cluster -c ${CLUSTER_ID} -o json

# Output
# Print console.url and api.url
API_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.api.url')
CONSOLE_URL=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.console.url')
if [[ "${API_URL}" == "null" ]]; then
  # If api.url is null, call ocm-qe to analyze the root cause.
  notify_ocmqe "Warning: the api.url for the cluster ${CLUSTER_ID} is null"

  port="6443"
  if [[ "$HOSTED_CP" == "true" ]]; then
    port="443"
  fi
  echo "warning: API URL was null, attempting to build API URL"
  base_domain=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.dns.base_domain')
  CLUSTER_NAME=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.name')
  echo "info: Using baseDomain : ${base_domain} and clusterName : ${CLUSTER_NAME}"
  API_URL="https://api.${CLUSTER_NAME}.${base_domain}:${port}"
  CONSOLE_URL="https://console-openshift-console.apps.${CLUSTER_NAME}.${base_domain}"
fi

echo "API URL: ${API_URL}"
echo "Console URL: ${CONSOLE_URL}"
echo "${CONSOLE_URL}" > "${SHARED_DIR}/console.url"
echo "${API_URL}" > "${SHARED_DIR}/api.url"

PRODUCT_ID=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.product.id')
echo "${PRODUCT_ID}" > "${SHARED_DIR}/cluster-type"

INFRA_ID=$(rosa describe cluster -c "${CLUSTER_ID}" -o json | jq -r '.infra_id')
if [[ "$HOSTED_CP" == "true" ]] && [[ "${INFRA_ID}" == "null" ]]; then
  # Currently, there is no infra_id for rosa hypershift cluster, use a fake one instead of null
  INFRA_ID=$CLUSTER_NAME
fi
echo "${INFRA_ID}" > "${SHARED_DIR}/infra_id"
