#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export STORAGECLASS_LOCATION=${SHARED_DIR}/efs-sc.yaml

REGION=${REGION:-$LEASED_RESOURCE}
FILESYSTEM_ID=$(yq-go r "${STORAGECLASS_LOCATION}" 'parameters.fileSystemId')

# Special setting for C2S/SC2S
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

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

# Function to check if all mount targets are deleted
# Calling the function with arguments
# wait_for_mount_targets_deleted "file_system_id" "region"
function wait_for_mount_targets_deleted() {
    local file_system_id="$1"
    local region="$2"
    local timeout=300  # Maximum wait time in seconds
    local interval=10  # Interval between checks in seconds
    local elapsed=0

    while : ; do
        # List all mount targets
        mount_targets=$(aws efs describe-mount-targets --file-system-id "$file_system_id" --region "$region" --query 'MountTargets[*].MountTargetId' --output text)

        if [ -z "$mount_targets" ]; then
            logger "INFO" "All mount targets are deleted."
            break
        else
            logger "INFO" "Waiting next $interval seconds for mount targets to be deleted..."
            sleep $interval
            (( elapsed += interval ))

            # Check if timeout has been reached
            if (( elapsed >= timeout )); then
                logger "ERROR" "Timeout reached: Not all mount targets were deleted within $timeout seconds."
                break
            fi
        fi
    done
}

# Delete each Access Point
for ap in $(aws efs describe-access-points --region "${REGION}" --file-system-id "${FILESYSTEM_ID}" --query 'AccessPoints[*].AccessPointId' --output text); do
  aws efs delete-access-point --region "${REGION}" --access-point-id "$ap"
  logger "INFO" "Access-point $ap deleted ..."
done

# Delete each Mount Target
for mt in $(aws efs describe-mount-targets --region "${REGION}" --file-system-id "${FILESYSTEM_ID}" --query 'MountTargets[*].MountTargetId' --output text); do
  aws efs delete-mount-target --region "${REGION}" --mount-target-id "$mt"
  logger "INFO" "Mount-target $mt deleted ..."
done

wait_for_mount_targets_deleted "${FILESYSTEM_ID}" "${REGION}"

# Delete the EFS File System
aws efs delete-file-system --region "${REGION}" --file-system-id "${FILESYSTEM_ID}"
logger "INFO" "Aws efs volume ${FILESYSTEM_ID} deleted ..."
