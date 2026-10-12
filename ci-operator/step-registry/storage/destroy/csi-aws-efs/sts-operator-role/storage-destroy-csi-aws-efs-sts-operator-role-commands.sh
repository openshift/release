#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

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

delete_iam_role_safely() {

    local ROLE_ARN="$1"
    local ROLE_NAME="${ROLE_ARN##*/}"

    logger "INFO" "Processing IAM role: $ROLE_NAME"

    # Delete inline policies
    INLINE_POLICIES=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames' --output text)
    for POLICY in $INLINE_POLICIES; do
        aws iam delete-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY"
        logger "INFO" "Inline policy '$POLICY' deleted successfully."
    done

    # Detach and conditionally delete managed policies
    MANAGED_POLICIES=$(aws iam list-attached-role-policies --role-name "$ROLE_NAME" --query 'AttachedPolicies[*].PolicyArn' --output text)
    for POLICY_ARN in $MANAGED_POLICIES; do
        aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"
        logger "INFO" "Managed policy '$POLICY_ARN' detached from role."

        # Check if it's a customer-managed policy and not used elsewhere
        IS_CUSTOM=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Arn' --output text 2>/dev/null || true)
        if [[ -n "$IS_CUSTOM" ]]; then
            ATTACH_COUNT=$(aws iam list-entities-for-policy --policy-arn "$POLICY_ARN" --query 'PolicyRoles | length(@)' --output text)
            if [[ "$ATTACH_COUNT" -eq 0 ]]; then
                aws iam delete-policy --policy-arn "$POLICY_ARN"
                logger "INFO" "Managed policy '$POLICY_ARN' deleted (no longer in use)."
            else
                logger "WARN" "Policy '$POLICY_ARN' still in use elsewhere; skipping delete."
            fi
        fi
    done

    # Delete the role itself
    aws iam delete-role --role-name "$ROLE_NAME"
    logger "INFO" "IAM role '$ROLE_NAME' deleted successfully."
}

if [[ -s "${SHARED_DIR}/efs-csi-driver-operator-role-arn" ]]; then
  ROLE_ARN=$(cat "${SHARED_DIR}"/efs-csi-driver-operator-role-arn)
  delete_iam_role_safely "${ROLE_ARN}"
fi

if [[ ${ENABLE_CROSS_ACCOUNT} == "yes" ]]; then
  # Cross account clusters switch to the shared account
  # delete the iam role (operator assume role) in account B
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
  logger "INFO" "Using shared AWS account ..."

  if [[ -s "${SHARED_DIR}/cross-account-efs-csi-driver-operator-role-arn" ]]; then
    CROSS_ACCOUNT_ROLE_ARN=$(cat "${SHARED_DIR}"/cross-account-efs-csi-driver-operator-role-arn)
    delete_iam_role_safely "${CROSS_ACCOUNT_ROLE_ARN}"
  fi
fi
