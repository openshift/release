#!/bin/bash

set -euo pipefail

echo "=== AWS CSPI-QE Resource Cleanup ==="
echo "Regions: ${CLEANUP_REGIONS}"
echo "Min age: ${CLEANUP_MIN_AGE}"

# Configure AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Clone openshift/hypershift at a pinned commit and build the cleanleaked tool
# Update this SHA periodically to pick up cleanleaked improvements
HYPERSHIFT_SHA="a98bd6d40025667761387f9d9589e75140c7fbc0"
echo ""
echo "=== Cloning openshift/hypershift at ${HYPERSHIFT_SHA} ==="
HYPERSHIFT_DIR=$(mktemp -d)
git clone --depth 1 https://github.com/openshift/hypershift.git "${HYPERSHIFT_DIR}"
cd "${HYPERSHIFT_DIR}"
git fetch --depth 1 origin "${HYPERSHIFT_SHA}"
git checkout "${HYPERSHIFT_SHA}"

echo ""
echo "=== Building cleanleaked ==="
cd "${HYPERSHIFT_DIR}/contrib/aws-leaked-resources"
export GOTOOLCHAIN=auto
go build -o /tmp/cleanleaked .
echo "cleanleaked built successfully"

# Loop over each comma-separated region
IFS=',' read -ra REGIONS <<< "${CLEANUP_REGIONS}"
for region in "${REGIONS[@]}"; do
  region=$(echo "${region}" | xargs)  # trim whitespace
  echo ""
  echo "=== Running scan for region ${region} (report only) ==="
  /tmp/cleanleaked scan --min-age "${CLEANUP_MIN_AGE}" --region "${region}" || true

  echo ""
  echo "=== Running delete for region ${region} (min-age ${CLEANUP_MIN_AGE}) ==="
  /tmp/cleanleaked delete --confirm --min-age "${CLEANUP_MIN_AGE}" --region "${region}"
done

# ============================================================
# IAM Role and Instance Profile Cleanup (Global – run once)
# ============================================================
# cleanleaked cascades IAM cleanup from VPC/OIDC deletion but does NOT
# independently enumerate standalone IAM roles/profiles. Orphaned roles
# from failed deprovisioning accumulate and can hit the 1000-role AWS
# quota. This section finds roles/profiles created by the OCP IPI
# installer (by suffix) and removes stale ones directly.

echo ""
echo "=== Installing AWS CLI v2 ==="
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && ./aws/install --bin-dir /tmp/aws-bin --install-dir /tmp/aws-cli 2>/dev/null
export PATH="/tmp/aws-bin:${PATH}"
aws --version

# IAM is a global service; use us-east-1 for the API endpoint
export AWS_DEFAULT_REGION="us-east-1"

# Parse CLEANUP_MIN_AGE (e.g. "24h") into hours for age comparison
MIN_AGE_HOURS=$(echo "${CLEANUP_MIN_AGE}" | sed -n 's/^\([0-9]*\)h$/\1/p')
if [[ -z "${MIN_AGE_HOURS}" ]]; then
  echo "ERROR: CLEANUP_MIN_AGE='${CLEANUP_MIN_AGE}' must be '<N>h' for IAM cleanup" >&2
  exit 1
fi
CUTOFF_EPOCH=$(date -d "${MIN_AGE_HOURS} hours ago" +%s)
echo "Age threshold: ${MIN_AGE_HOURS}h (cutoff: $(date -d "@${CUTOFF_EPOCH}" -u +%Y-%m-%dT%H:%M:%SZ))"

# ---- IAM Roles ----
echo ""
echo "=== Cleaning up orphaned IAM roles (-master-role / -worker-role) ==="
ROLES_DELETED=0
ROLES_SKIPPED_YOUNG=0
ROLES_SKIPPED_UNTAGGED=0

ROLE_DATA=$(aws iam list-roles \
  --query 'Roles[*].[RoleName,CreateDate]' --output text | \
  grep -E '(-master-role|-worker-role)[[:space:]]' | sort) || true

while IFS=$'\t' read -r role_name create_date; do
  [[ -z "${role_name}" ]] && continue

  # Check age: skip roles newer than the threshold
  role_epoch=$(date -d "${create_date}" +%s 2>/dev/null || echo "0")
  if (( role_epoch > CUTOFF_EPOCH )); then
    echo "  SKIP (young): ${role_name} created ${create_date}"
    (( ROLES_SKIPPED_YOUNG++ )) || true
    continue
  fi

  # Safety gate: require kubernetes.io/cluster/<infraID> tag
  K8S_TAG=$(aws iam list-role-tags --role-name "${role_name}" \
    --query 'Tags[?starts_with(Key, `kubernetes.io/cluster/`)].Key' \
    --output text 2>/dev/null) || true
  if [[ -z "${K8S_TAG}" ]]; then
    echo "  SKIP (no k8s tag): ${role_name}"
    (( ROLES_SKIPPED_UNTAGGED++ )) || true
    continue
  fi

  # Extract infraID from tag key (kubernetes.io/cluster/<infraID>)
  INFRA_ID="${K8S_TAG#kubernetes.io/cluster/}"
  INFRA_ID="${INFRA_ID%%[[:space:]]*}"

  # Check if cluster still has resources in any region
  CLUSTER_ALIVE=""
  for r in "${REGIONS[@]}"; do
    r=$(echo "${r}" | xargs)
    # Check VPCs
    VPC_OUT=""
    if ! VPC_OUT=$(aws ec2 describe-vpcs --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
      --query 'Vpcs[*].VpcId' --output text 2>/dev/null); then
      echo "  SKIP (VPC lookup failed in ${r}): ${role_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${VPC_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
    # Check running EC2 instances
    INST_OUT=""
    if ! INST_OUT=$(aws ec2 describe-instances --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
                "Name=instance-state-name,Values=running,pending,stopping,stopped" \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null); then
      echo "  SKIP (instance lookup failed in ${r}): ${role_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${INST_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
  done
  if [[ "${CLUSTER_ALIVE}" == "true" ]]; then
    echo "  SKIP (cluster still has VPCs/instances): ${role_name} [infraID: ${INFRA_ID}]"
    continue
  fi

  echo "  DELETE: ${role_name} (created ${create_date}, tag: ${K8S_TAG})"

  # Detach all managed policies
  ATTACHED=$(aws iam list-attached-role-policies --role-name "${role_name}" \
    --query 'AttachedPolicies[*].PolicyArn' --output text) || true
  for arn in ${ATTACHED}; do
    [[ "${arn}" == "None" ]] && continue
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${arn}" || true
  done

  # Delete all inline policies
  INLINE=$(aws iam list-role-policies --role-name "${role_name}" \
    --query 'PolicyNames[*]' --output text) || true
  for pol in ${INLINE}; do
    [[ "${pol}" == "None" ]] && continue
    aws iam delete-role-policy --role-name "${role_name}" --policy-name "${pol}" || true
  done

  # Remove from any instance profiles
  INST_PROFILES=$(aws iam list-instance-profiles-for-role --role-name "${role_name}" \
    --query 'InstanceProfiles[*].InstanceProfileName' --output text) || true
  for ip in ${INST_PROFILES}; do
    [[ "${ip}" == "None" ]] && continue
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${ip}" --role-name "${role_name}" || true
  done

  # Delete the role
  if aws iam delete-role --role-name "${role_name}"; then
    (( ROLES_DELETED++ )) || true
  fi
done <<< "${ROLE_DATA}"

echo "IAM Roles: deleted=${ROLES_DELETED} skipped-young=${ROLES_SKIPPED_YOUNG} skipped-untagged=${ROLES_SKIPPED_UNTAGGED}"

# ---- Instance Profiles ----
echo ""
echo "=== Cleaning up orphaned instance profiles (-master-profile / -worker-profile) ==="
PROFILES_DELETED=0
PROFILES_SKIPPED_YOUNG=0
PROFILES_SKIPPED_UNTAGGED=0

PROFILE_DATA=$(aws iam list-instance-profiles \
  --query 'InstanceProfiles[*].[InstanceProfileName,CreateDate]' --output text | \
  grep -E '(-master-profile|-worker-profile)[[:space:]]' | sort) || true

while IFS=$'\t' read -r profile_name create_date; do
  [[ -z "${profile_name}" ]] && continue

  # Check age
  profile_epoch=$(date -d "${create_date}" +%s 2>/dev/null || echo "0")
  if (( profile_epoch > CUTOFF_EPOCH )); then
    echo "  SKIP (young): ${profile_name} created ${create_date}"
    (( PROFILES_SKIPPED_YOUNG++ )) || true
    continue
  fi

  # Safety gate: require kubernetes.io/cluster/<infraID> tag
  K8S_TAG=$(aws iam list-instance-profile-tags --instance-profile-name "${profile_name}" \
    --query 'Tags[?starts_with(Key, `kubernetes.io/cluster/`)].Key' \
    --output text 2>/dev/null) || true
  if [[ -z "${K8S_TAG}" ]]; then
    echo "  SKIP (no k8s tag): ${profile_name}"
    (( PROFILES_SKIPPED_UNTAGGED++ )) || true
    continue
  fi

  # Extract infraID from tag key (kubernetes.io/cluster/<infraID>)
  INFRA_ID="${K8S_TAG#kubernetes.io/cluster/}"
  INFRA_ID="${INFRA_ID%%[[:space:]]*}"

  # Check if cluster still has resources in any region
  CLUSTER_ALIVE=""
  for r in "${REGIONS[@]}"; do
    r=$(echo "${r}" | xargs)
    # Check VPCs
    VPC_OUT=""
    if ! VPC_OUT=$(aws ec2 describe-vpcs --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
      --query 'Vpcs[*].VpcId' --output text 2>/dev/null); then
      echo "  SKIP (VPC lookup failed in ${r}): ${profile_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${VPC_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
    # Check running EC2 instances
    INST_OUT=""
    if ! INST_OUT=$(aws ec2 describe-instances --region "${r}" \
      --filters "Name=tag-key,Values=kubernetes.io/cluster/${INFRA_ID}" \
                "Name=instance-state-name,Values=running,pending,stopping,stopped" \
      --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null); then
      echo "  SKIP (instance lookup failed in ${r}): ${profile_name}"
      CLUSTER_ALIVE="true"
      break
    fi
    if [[ -n "${INST_OUT}" ]]; then
      CLUSTER_ALIVE="true"
      break
    fi
  done
  if [[ "${CLUSTER_ALIVE}" == "true" ]]; then
    echo "  SKIP (cluster still has VPCs/instances): ${profile_name} [infraID: ${INFRA_ID}]"
    continue
  fi

  echo "  DELETE: ${profile_name} (created ${create_date}, tag: ${K8S_TAG})"

  # Remove all roles from the instance profile
  IP_ROLES=$(aws iam get-instance-profile --instance-profile-name "${profile_name}" \
    --query 'InstanceProfile.Roles[*].RoleName' --output text) || true
  for rn in ${IP_ROLES}; do
    [[ "${rn}" == "None" ]] && continue
    aws iam remove-role-from-instance-profile \
      --instance-profile-name "${profile_name}" --role-name "${rn}" || true
  done

  # Delete the instance profile
  if aws iam delete-instance-profile --instance-profile-name "${profile_name}"; then
    (( PROFILES_DELETED++ )) || true
  fi
done <<< "${PROFILE_DATA}"

echo "Instance Profiles: deleted=${PROFILES_DELETED} skipped-young=${PROFILES_SKIPPED_YOUNG} skipped-untagged=${PROFILES_SKIPPED_UNTAGGED}"

echo ""
echo "=== Cleanup complete ==="
