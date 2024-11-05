#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

ROLE_ARN=$(cat "${SHARED_DIR}"/efs-csi-driver-operator-role-arn)

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

# Extract the role name
ROLE_NAME="${ROLE_ARN##*/}"
logger "INFO" "The role name is: $ROLE_NAME"

# List and detach inline policies
INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text)
for POLICY in $INLINE_POLICIES; do
    aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY"
    logger "INFO" "Inline policy $POLICY deleted succeed ..."
done

# List and detach managed policies
MANAGED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text)
for POLICY in $MANAGED_POLICIES; do
    aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY"
    aws iam delete-policy --policy-arn "$POLICY"
    logger "INFO" "Managed policy $POLICY detach and deleted succeed ..."
done

aws iam delete-role --role-name "$ROLE_NAME"
logger "INFO" "$ROLE_NAME deleted succeed ..."
