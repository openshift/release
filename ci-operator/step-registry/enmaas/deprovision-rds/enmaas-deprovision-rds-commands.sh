#!/bin/bash
set -o nounset
set -o pipefail
# NOTE: errexit is intentionally NOT set so that cleanup proceeds even if
# individual steps fail.

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${REGION:-us-east-2}"

CLEANUP_EXIT_CODE=0

echo "Starting RDS cleanup..."

# Step 1: Delete the RDS instance (skip if no instance ID recorded)
if [[ -f "${SHARED_DIR}/rds-instance-id" ]]; then
  INSTANCE_ID=$(cat "${SHARED_DIR}/rds-instance-id")
  echo "Deleting RDS instance: ${INSTANCE_ID}..."
  if aws rds delete-db-instance \
    --db-instance-identifier "${INSTANCE_ID}" \
    --skip-final-snapshot \
    --region "${REGION}" 2>&1; then
    echo "RDS instance deletion initiated."

    # Wait for instance to be fully deleted (timeout after 15 minutes)
    echo "Waiting for RDS instance to be deleted..."
    if aws rds wait db-instance-deleted \
      --db-instance-identifier "${INSTANCE_ID}" \
      --region "${REGION}" 2>&1; then
      echo "RDS instance deleted successfully."
    else
      echo "WARNING: Timed out waiting for RDS instance deletion. It may still be deleting."
      CLEANUP_EXIT_CODE=1
    fi
  else
    echo "WARNING: Failed to delete RDS instance ${INSTANCE_ID}. It may already be deleted."
    CLEANUP_EXIT_CODE=1
  fi
else
  echo "No RDS instance ID found (${SHARED_DIR}/rds-instance-id missing), skipping instance deletion."
fi

# Step 2: Delete the DB subnet group
if [[ -f "${SHARED_DIR}/rds-subnet-group" ]]; then
  SUBNET_GROUP_NAME=$(cat "${SHARED_DIR}/rds-subnet-group")
  if [[ -n "${SUBNET_GROUP_NAME}" ]]; then
    echo "Deleting DB subnet group: ${SUBNET_GROUP_NAME}..."
    if aws rds delete-db-subnet-group \
      --db-subnet-group-name "${SUBNET_GROUP_NAME}" \
      --region "${REGION}" 2>&1; then
      echo "DB subnet group deleted."
    else
      echo "WARNING: Failed to delete DB subnet group ${SUBNET_GROUP_NAME}."
      CLEANUP_EXIT_CODE=1
    fi
  fi
else
  echo "No DB subnet group name found (${SHARED_DIR}/rds-subnet-group missing), skipping."
fi

# Step 3: Delete the security group
if [[ -f "${SHARED_DIR}/rds-security-group-id" ]]; then
  SG_ID=$(cat "${SHARED_DIR}/rds-security-group-id")
  if [[ -n "${SG_ID}" ]]; then
    echo "Deleting security group: ${SG_ID}..."
    if aws ec2 delete-security-group \
      --group-id "${SG_ID}" \
      --region "${REGION}" 2>&1; then
      echo "Security group deleted."
    else
      echo "WARNING: Failed to delete security group ${SG_ID}."
      CLEANUP_EXIT_CODE=1
    fi
  fi
else
  echo "No security group ID found (${SHARED_DIR}/rds-security-group-id missing), skipping."
fi

if [[ "${CLEANUP_EXIT_CODE}" -ne 0 ]]; then
  echo "WARNING: Some RDS cleanup steps had errors. Check the logs above."
fi

echo "RDS cleanup complete."
exit "${CLEANUP_EXIT_CODE}"
