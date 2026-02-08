#!/bin/bash

set -o nounset
set -o pipefail
# Note: NOT using errexit because we handle errors manually

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# This is a wrapper around rosa cluster creation that handles the "zero egress"
# CLI bug where the ROSA CLI returns exit code 1 after successfully creating
# a cluster due to failing to parse an empty boolean field.

HOSTED_CP=${HOSTED_CP:-true}
COMPUTE_MACHINE_TYPE=${COMPUTE_MACHINE_TYPE:-"inf2.xlarge"}
OPENSHIFT_VERSION=${OPENSHIFT_VERSION:-}
REPLICAS=${REPLICAS:-"2"}
CHANNEL_GROUP=${CHANNEL_GROUP:-"candidate,stable"}
ENABLE_BYOVPC=${ENABLE_BYOVPC:-true}
CLUSTER_TAGS=${CLUSTER_TAGS:-""}

CLUSTER_PREFIX=$(head -n 1 "${SHARED_DIR}/cluster-prefix")
CLUSTER_NAME=${CLUSTER_NAME:-$CLUSTER_PREFIX}

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Configure AWS
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
if [[ "$HOSTED_CP" == "true" ]] && [[ -n "${REGION:-}" ]]; then
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

# Log in to OCM
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

# Get OpenShift version
get_version() {
  local channel="$1"
  local target="$2"
  
  versions=$(rosa list versions --channel-group "${channel}" --hosted-cp -o json | jq -r '.[].raw_id')
  
  if [[ -n "$target" ]]; then
    echo "$versions" | grep -E "^${target}" | head -1
  else
    echo "$versions" | head -1
  fi
}

# Find version across channel groups
IFS=',' read -r -a CHANNELS <<< "${CHANNEL_GROUP// /}"
SELECTED_VERSION=""
SELECTED_CHANNEL=""

for channel in "${CHANNELS[@]}"; do
  log "Checking ${channel} channel for version ${OPENSHIFT_VERSION:-latest}..."
  SELECTED_VERSION=$(get_version "${channel}" "${OPENSHIFT_VERSION}")
  if [[ -n "$SELECTED_VERSION" ]]; then
    SELECTED_CHANNEL="${channel}"
    log "Found version ${SELECTED_VERSION} in ${channel} channel"
    break
  fi
done

if [[ -z "$SELECTED_VERSION" ]]; then
  echo "Error: Could not find suitable OpenShift version"
  exit 1
fi

echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

# Build tags
TAG_Author=$(echo "${JOB_SPEC}" | jq -r '.refs.pulls[].author // empty' | tr -d '[]' || true)
TAG_Author=${TAG_Author:-"periodic"}
TAG_Pull_Number=${PULL_NUMBER:-"periodic"}
TAGS="usage-user:${TAG_Author},usage-pull-request:${TAG_Pull_Number},usage-cluster-type:rosa-hcp,usage-ci-type:prow,usage-job-type:${JOB_TYPE}"
if [[ -n "$CLUSTER_TAGS" ]]; then
  TAGS="${TAGS},${CLUSTER_TAGS}"
fi

# Get subnet IDs for BYOVPC
SUBNET_IDS=""
if [[ "$ENABLE_BYOVPC" == "true" ]]; then
  PUBLIC_SUBNET_IDs=$(cat ${SHARED_DIR}/public_subnet_ids | tr -d "[']")
  PRIVATE_SUBNET_IDs=$(cat ${SHARED_DIR}/private_subnet_ids | tr -d "[']")
  SUBNET_IDS="${PUBLIC_SUBNET_IDs},${PRIVATE_SUBNET_IDs}"
fi

# Get account roles
roleARNFile="${SHARED_DIR}/account-roles-arns"
account_installer_role_arn=$(cat "$roleARNFile" | grep "Installer-Role" || true)
account_support_role_arn=$(cat "$roleARNFile" | grep "Support-Role" || true)
account_worker_role_arn=$(cat "$roleARNFile" | grep "Worker-Role" || true)

if [[ -z "${account_installer_role_arn}" ]] || [[ -z "${account_support_role_arn}" ]] || [[ -z "${account_worker_role_arn}" ]]; then
  echo "Error: Missing account roles"
  exit 1
fi

# Get OIDC config
oidc_config_id=$(cat "${SHARED_DIR}/oidc-config" | jq -r '.id')
operator_roles_prefix=$CLUSTER_PREFIX

# Initialize cluster-config file for downstream steps
cat > "${SHARED_DIR}/cluster-config" << EOF
{
  "name": "${CLUSTER_NAME}",
  "sts": true,
  "hypershift": true,
  "region": "${CLOUD_PROVIDER_REGION}",
  "version": {
    "channel_group": "${SELECTED_CHANNEL}",
    "raw_id": "${SELECTED_VERSION}"
  }
}
EOF

log "Creating ROSA HCP cluster: ${CLUSTER_NAME}"
log "  Region: ${CLOUD_PROVIDER_REGION}"
log "  Version: ${SELECTED_VERSION}"
log "  Machine type: ${COMPUTE_MACHINE_TYPE}"
log "  Replicas: ${REPLICAS}"

# Build and execute the create command
cmd="rosa create cluster -y --sts --hosted-cp \
  --cluster-name ${CLUSTER_NAME} \
  --region ${CLOUD_PROVIDER_REGION} \
  --version ${SELECTED_VERSION} \
  --channel-group ${SELECTED_CHANNEL} \
  --compute-machine-type ${COMPUTE_MACHINE_TYPE} \
  --tags ${TAGS} \
  --role-arn ${account_installer_role_arn} \
  --support-role-arn ${account_support_role_arn} \
  --worker-iam-role ${account_worker_role_arn} \
  --replicas ${REPLICAS} \
  --oidc-config-id ${oidc_config_id} \
  --operator-roles-prefix ${operator_roles_prefix} \
  --subnet-ids ${SUBNET_IDS}"

log "Running command:"
echo "$cmd" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g"

# Execute and capture output with retry logic
max_retries=3
retry_count=0
exit_code=1
cmd_output=""

while [ $retry_count -lt $max_retries ]; do
  echo "Attempt $((retry_count + 1)) of $max_retries..."
  
  cmd_output=$(eval "${cmd}" 2>&1)
  exit_code=$?
  
  echo "$cmd_output"
  
  # Check for retryable errors
  if [[ "$cmd_output" =~ "does not have release image for" ]]; then
    echo "Retryable error detected. Sleeping for 10 minutes before retry..."
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      sleep 600
    fi
    continue
  fi
  
  # Check if cluster was created despite potential error (handles zero egress bug)
  if echo "$cmd_output" | grep -q "Cluster '${CLUSTER_NAME}' has been created"; then
    log "Cluster creation confirmed successful"
    
    if echo "$cmd_output" | grep -q "Failed to get zero egress info"; then
      log "WARNING: Ignoring 'zero egress' CLI bug - cluster was created successfully"
    fi
    exit_code=0
    break
  fi
  
  # If we get here with non-zero exit and no cluster created, it's a real failure
  if [ $exit_code -ne 0 ]; then
    echo "Command failed with non-retryable error, exit code: $exit_code"
    break
  fi
  
  break
done

# Save install status for gather steps
echo $exit_code > "${SHARED_DIR}/install-status.txt"

if [[ $exit_code -ne 0 ]]; then
  echo "Cluster creation failed"
  exit $exit_code
fi

# Get cluster ID - try multiple methods
CLUSTER_ID=""

# Method 1: Parse from output
CLUSTER_ID=$(echo "$cmd_output" | grep '^ID:' | tr -d '[:space:]' | cut -d ':' -f 2 || true)

# Method 2: rosa describe
if [[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]]; then
  log "Fetching cluster ID via rosa describe..."
  CLUSTER_ID=$(rosa describe cluster -c "${CLUSTER_NAME}" -o json 2>/dev/null | jq -r '.id' || true)
fi

# Method 3: rosa list
if [[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]]; then
  log "Fetching cluster ID via rosa list..."
  CLUSTER_ID=$(rosa list clusters -o json | jq -r ".[] | select(.name==\"${CLUSTER_NAME}\") | .id" || true)
fi

if [[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]]; then
  echo "Error: Could not determine cluster ID"
  exit 1
fi

echo "Cluster ${CLUSTER_NAME} created with ID: ${CLUSTER_ID}"
echo -n "${CLUSTER_ID}" > "${SHARED_DIR}/cluster-id"

# Save cluster info to artifacts
echo "$cmd_output" | sed "s/$AWS_ACCOUNT_ID/$AWS_ACCOUNT_ID_MASK/g" > "${ARTIFACT_DIR}/cluster.txt"

log "Cluster provision step completed successfully"
