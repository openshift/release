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
CLUSTER_SECTOR=${CLUSTER_SECTOR:-}
ADDITIONAL_SECURITY_GROUP=${ADDITIONAL_SECURITY_GROUP:-false}
NO_CNI=${NO_CNI:-false}
CONFIGURE_CLUSTER_AUTOSCALER=${CONFIGURE_CLUSTER_AUTOSCALER:-false}
CLUSTER_PREFIX=$(head -n 1 "${SHARED_DIR}/cluster-prefix")

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

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
CLUSTER_NAME=""
DOMAIN_PREFIX_SWITCH=""
if [[ ${ENABLE_SHARED_VPC} == "yes" ]] && [[ -e "${SHARED_DIR}/cluster-name" ]]; then
  # For Shared VPC cluster, cluster name is determined in step aws-provision-route53-private-hosted-zone
  #   as Private Hosted Zone needs to be ready before installing Shared VPC cluster
  CLUSTER_NAME=$(head -n 1 "${SHARED_DIR}/cluster-name")
else
  CLUSTER_NAME=${CLUSTER_NAME:-$CLUSTER_PREFIX}
  # For long cluster name enabled, append a "long_name_prefix_len" chars long random string to cluster name
  # Max possible prefix length is 14, hyppen is used 1 times, random string of length "long_name_prefix_len"
  # (14 + 1 + "long_name_prefix_len" = 54 )
  MAX_CLUSTER_NAME_LENGTH=54
  if [[ "$LONG_CLUSTER_NAME_ENABLED" == "true" ]]; then
    long_name_prefix_len=$(( MAX_CLUSTER_NAME_LENGTH - $(echo -n "$CLUSTER_NAME" | wc -c) - 1 ))
    long_name_prefix=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c $long_name_prefix_len)
    CLUSTER_NAME="$CLUSTER_PREFIX-$long_name_prefix"
  fi

  #set the domain prefix of length (<=15)
  MAX_DOMAIN_PREFIX_LENGTH=15
  if [[ "$SPECIFY_DOMAIN_PREFIX" == "true" ]]; then
    first_char=$(head /dev/urandom | tr -dc 'a-z' | head -c 1)
    remaining_chars=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c $((MAX_DOMAIN_PREFIX_LENGTH - 1)))
    DOMAIN_PREFIX="$first_char$remaining_chars"
    DOMAIN_PREFIX_SWITCH="--domain-prefix $DOMAIN_PREFIX"
  fi
  #else the domain prefix will be auto generated.
fi
echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

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
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi
AWS_ACCOUNT_ID=$(rosa whoami --output json | jq -r '."AWS Account ID"')
AWS_ACCOUNT_ID_MASK=$(echo "${AWS_ACCOUNT_ID:0:4}***")

if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  if [[ ! -e "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
    echo "Error: Shared VPC is enabled, but not find .awscred_shared_account, exit now"
    exit 1
  fi
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  SHARED_VPC_AWS_ACCOUNT_ID=$(aws sts get-caller-identity --output text | awk '{print $1}')
  SHARED_VPC_AWS_ACCOUNT_ID_MASK=$(echo "${SHARED_VPC_AWS_ACCOUNT_ID:0:4}***")

  # reset
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
fi

# Check whether the cluster with the same cluster name exists.
OLD_CLUSTER=$(rosa list clusters | { grep  ${CLUSTER_NAME} || true; })
if [[ ! -z "$OLD_CLUSTER" ]]; then
  # Previous cluster was orphaned somehow. Shut it down.
  log -e "A cluster with the name (${CLUSTER_NAME}) already exists and will need to be manually deleted; cluster: \n${OLD_CLUSTER}"
  exit 1
fi

# Get the openshift version
version_cmd="rosa list versions --channel-group ${CHANNEL_GROUP} -o json"
if [[ "$HOSTED_CP" == "true" ]]; then
  version_cmd="$version_cmd --hosted-cp"
fi
if [[ ${AVAILABLE_UPGRADE} == "yes" ]] ; then
  # shellcheck disable=SC2089
  version_cmd="$version_cmd | jq -r '.[] | select(.available_upgrades!=null) .raw_id'"
else
  version_cmd="$version_cmd | jq -r '.[].raw_id'"
fi
versionList=$(eval $version_cmd)
echo -e "Available cluster versions:\n${versionList}"

# If OPENSHIFT_VERSION is set to "release:latest", look at the environment variable
# supplied by CI for the payload to use. This only really works for nightlies. ROSA
# SRE has a job that polls the release controller and syncs new nightlies every 15 minutes,
# and it can take for up to 60 minutes in practice for the nightly to be available and listed
# from the ROSA CLI, so we keep retrying with a back off.
if [[ "$OPENSHIFT_VERSION" = "release:latest" ]]; then
    PAYLOAD_TAG=$(echo $ORIGINAL_RELEASE_IMAGE_LATEST | cut -d':' -f2)

    DELAY=60
    MAX_DELAY=360
    TIME_LIMIT=3600
    start_time=$(date +%s)

    while true; do
        # Check if image has been synced yet
        if eval "$version_cmd" | grep -q "$PAYLOAD_TAG"; then
            echo "$PAYLOAD_TAG is available from ROSA, continuing..."
            OPENSHIFT_VERSION=$PAYLOAD_TAG
            break
        fi

        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))

        # Don't wait longer than $TIME_LIMIT for the payload to be synced
        if [[ $elapsed_time -ge $TIME_LIMIT ]]; then
            minutes=$((TIME_LIMIT / 60))
            echo "Error: timed out after $minutes minutes waiting for $PAYLOAD_TAG to become available"
            exit 1
        fi

        # Wait for the current delay before retrying
        echo "Payload tag not found. Waiting for $DELAY seconds before retrying..."
        sleep $DELAY

        # Double the delay for exponential back-off, but cap it at the max delay
        DELAY=$((DELAY * 2))
        if [[ $DELAY -gt $MAX_DELAY ]]; then
            DELAY=$MAX_DELAY
        fi
    done
fi

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
log "Choosing openshift version ${OPENSHIFT_VERSION}"

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
    "raw_id": "${OPENSHIFT_VERSION}",
    "major_version": "$(echo ${OPENSHIFT_VERSION} | awk -F. '{print $1"."$2}')"
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

BILLING_ACCOUNT_SWITCH=""
if [[ "$ENABLE_BILLING_ACCOUNT" == "yes" ]]; then
  BILLING_ACCOUNT=$(head -n 1 ${CLUSTER_PROFILE_DIR}/aws_billing_account)
  BILLING_ACCOUNT_SWITCH="--billing-account ${BILLING_ACCOUNT}"
  record_cluster "billing_account" ${BILLING_ACCOUNT}

  BILLING_ACCOUNT_MASK=$(echo "${BILLING_ACCOUNT:0:4}***")
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
  record_cluster "nodes" "install_nodes" ${MIN_REPLICAS}
  record_cluster "nodes" "min_replicas" ${MIN_REPLICAS}
  record_cluster "nodes" "max_replicas" ${MAX_REPLICAS}
else
  COMPUTE_NODES_SWITCH="--replicas ${REPLICAS}"
  record_cluster "nodes" "install_nodes" ${REPLICAS}
  record_cluster "nodes" "replicas" ${REPLICAS}
fi

CONFIGURE_CLUSTER_AUTOSCALER_SWITCH=""
if [[ "$ENABLE_AUTOSCALING" == "true" ]] && [[ "$CONFIGURE_CLUSTER_AUTOSCALER" == "true" ]] && [[ "$HOSTED_CP" == "false" ]]; then
  CONFIGURE_CLUSTER_AUTOSCALER_SWITCH="--autoscaler-balance-similar-node-groups --autoscaler-skip-nodes-with-local-storage --autoscaler-ignore-daemonsets-utilization --autoscaler-scale-down-enabled"
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
  if [[ ! -z "${CLUSTER_SECTOR}" ]]; then
    psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('ready')" | jq -r '.items[].provision_shard_reference.id')
    if [[ -z "$psList" ]]; then
      echo "no ready provision shard found, trying to find maintenance status provision shard"
      # try to find maintenance mode SC, currently osdfm api doesn't support status in ('ready', 'maintenance') query.
      psList=$(ocm get /api/osd_fleet_mgmt/v1/service_clusters --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${CLOUD_PROVIDER_REGION}' and status in ('maintenance')" | jq -r '.items[].provision_shard_reference.id')
      if [[ -z "$psList" ]]; then
        echo "No available provision shard!"
        exit 1
      fi
    fi

    PROVISION_SHARD_ID=""
    # ensure the SC is not for ibm usage so that it could support the latest version of the hosted cluster
    for ps in $psList ; do
      topology=$(ocm get /api/clusters_mgmt/v1/provision_shards/${ps} | jq -r '.hypershift_config.topology')
      if [[ "$topology" == "dedicated" ]] || [[ "$topology" == "dedicated-v2" ]] ; then
      	PROVISION_SHARD_ID=${ps}
      fi
    done

    if [[ -z "$PROVISION_SHARD_ID" ]]; then
        echo "No available provision shard found! psList: $psList"
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
  SECURITY_GROUP_ID_SWITCH="--additional-compute-security-group-ids ${SECURITY_GROUP_IDs} --additional-infra-security-group-ids ${SECURITY_GROUP_IDs} --additional-control-plane-security-group-ids ${SECURITY_GROUP_IDs}"
  record_cluster "security_groups" "enabled" ${SECURITY_GROUP_IDs}
fi

# STS options
STS_SWITCH="--non-sts"
ACCOUNT_ROLES_SWITCH=""
BYO_OIDC_SWITCH=""
if [[ "$STS" == "true" ]]; then
  STS_SWITCH="--sts"

  # Account roles
  ACCOUNT_ROLES_PREFIX=$CLUSTER_PREFIX
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
    operator_roles_prefix=$CLUSTER_PREFIX
    BYO_OIDC_SWITCH="--oidc-config-id ${oidc_config_id} --operator-roles-prefix ${operator_roles_prefix}"
    record_cluster "aws.sts" "oidc_config_id" $oidc_config_id
    record_cluster "aws.sts" "operator_roles_prefix" $operator_roles_prefix
  else
    STS_SWITCH="${STS_SWITCH} --mode auto"
  fi
fi

SHARED_VPC_SWITCH=""
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  SAHRED_VPC_HOSTED_ZONE_ID=$(head -n 1 "${SHARED_DIR}/hosted_zone_id")
  SAHRED_VPC_ROLE_ARN=$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")
  SAHRED_VPC_BASE_DOMAIN=$(head -n 1 "${SHARED_DIR}/rosa_dns_domain")
  SHARED_VPC_SWITCH="--base-domain ${SAHRED_VPC_BASE_DOMAIN} --private-hosted-zone-id ${SAHRED_VPC_HOSTED_ZONE_ID} --shared-vpc-role-arn ${SAHRED_VPC_ROLE_ARN}"

  record_cluster "aws.sts" "private_hosted_zone_id" ${SAHRED_VPC_HOSTED_ZONE_ID}
  record_cluster "aws.sts" "private_hosted_zone_role_arn" ${SAHRED_VPC_ROLE_ARN}
  record_cluster "dns" "base_domain" ${SAHRED_VPC_BASE_DOMAIN}
fi

DRY_RUN_SWITCH=""
if [[ "$DRY_RUN" == "true" ]]; then
  DRY_RUN_SWITCH="--dry-run"
fi

NO_CNI_SWITCH=""
if [[ "$NO_CNI" == "true" ]]; then
  NO_CNI_SWITCH="--no-cni"
fi


# Save the cluster config to ARTIFACT_DIR
cat "${SHARED_DIR}/cluster-config" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g" > "${ARTIFACT_DIR}/cluster-config"

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
  echo "  Max replicas: ${MAX_REPLICAS}"
else
  echo "  Replicas: ${REPLICAS}"
fi
echo "  Config cluster autoscaler: ${CONFIGURE_CLUSTER_AUTOSCALER}"

echo "  Enable Shared VPC: ${ENABLE_SHARED_VPC}"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  echo "    SAHRED_VPC_HOSTED_ZONE_ID: ${SAHRED_VPC_HOSTED_ZONE_ID}"
  echo "    SAHRED_VPC_ROLE_ARN: ${SAHRED_VPC_ROLE_ARN}" | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g"
  echo "    SAHRED_VPC_BASE_DOMAIN: ${SAHRED_VPC_BASE_DOMAIN}"
fi

#Record installation start time
record_cluster "timers" "global_start" "$(date +'%s')"

# Provision cluster
cmd="rosa create cluster -y \
${STS_SWITCH} \
${HYPERSHIFT_SWITCH} \
--cluster-name ${CLUSTER_NAME} \
--region ${CLOUD_PROVIDER_REGION} \
--version ${OPENSHIFT_VERSION} \
--channel-group ${CHANNEL_GROUP} \
--compute-machine-type ${COMPUTE_MACHINE_TYPE} \
--tags ${TAGS} \
${DOMAIN_PREFIX_SWITCH} \
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
${NO_CNI_SWITCH} \
${CONFIGURE_CLUSTER_AUTOSCALER_SWITCH} \
${BILLING_ACCOUNT_SWITCH} \
${DRY_RUN_SWITCH}
"
echo "$cmd"| sed -E 's/\s{2,}/ /g' > "${SHARED_DIR}/create_cluster.sh"

log "Running command:"
cmdout=$(cat "${SHARED_DIR}/create_cluster.sh" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g")
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  cmdout=$(echo $cmdout | sed "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g")
fi
if [[ "$ENABLE_BILLING_ACCOUNT" == "yes" ]]; then
  cmdout=$(echo $cmdout | sed "s/${BILLING_ACCOUNT}/${BILLING_ACCOUNT_MASK}/g")
fi

echo "$cmdout"
CLUSTER_INFO_WITHOUT_MASK="$(mktemp)"
eval "${cmd}" > "${CLUSTER_INFO_WITHOUT_MASK}"

# Store the cluster ID for the post steps and the cluster deprovision
CLUSTER_INFO="${ARTIFACT_DIR}/cluster.txt"
cat ${CLUSTER_INFO_WITHOUT_MASK} | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g" > "${CLUSTER_INFO}"
if [[ ${ENABLE_SHARED_VPC} == "yes" ]]; then
  sed -i "s/${SHARED_VPC_AWS_ACCOUNT_ID}/${SHARED_VPC_AWS_ACCOUNT_ID_MASK}/g" "${CLUSTER_INFO}"
fi
CLUSTER_ID=$(cat "${CLUSTER_INFO}" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2)
echo "Cluster ${CLUSTER_NAME} is being created with cluster-id: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"
