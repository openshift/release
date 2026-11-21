#!/bin/bash
set -o nounset
set -o pipefail
set +e
set +x

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-us-east-2}"
if [[ ! "${BUILD_ID}" =~ ^[0-9]{1,20}$ ]]; then
  echo "ERROR: BUILD_ID must contain 1 to 20 digits."
  exit 1
fi
DEADLINE=$((SECONDS + 2400))
CLEANUP_EXIT_CODE=0
AWS_OUTPUT=""

pause_cleanup() {
  local remaining=$((DEADLINE - SECONDS))
  ((remaining > 0)) || return 1
  ((remaining > 15)) && remaining=15
  sleep "${remaining}"
}

aws_call() {
  local missing="$1" remaining status code
  shift
  while ((SECONDS < DEADLINE)); do
    remaining=$((DEADLINE - SECONDS))
    if AWS_OUTPUT=$(timeout "${remaining}s" aws "$@" --region "${REGION}" \
      --cli-connect-timeout 5 --cli-read-timeout 30 2>&1); then
      return 0
    else
      status=$?
    fi
    code=UnknownError
    if [[ "${AWS_OUTPUT}" =~ \(([A-Za-z0-9.]+)\) ]]; then
      code="${BASH_REMATCH[1]}"
    fi
    if [[ "${code}" == "${missing}" ]]; then
      return 2
    fi
    case "${code}" in
      Throttling|ThrottlingException|RequestLimitExceeded|ServiceUnavailable|InternalFailure|InternalError|RequestTimeout|DependencyViolation|InvalidDBSubnetGroupStateFault|InvalidDBInstanceState)
        echo "Retrying AWS $1 $2 after ${code}." ;;
      *)
        if [[ "${status}" != 124 && "${status}" != 137 ]]; then
          echo "ERROR: AWS $1 $2 failed (${code}, exit ${status})."
          return 1
        fi ;;
    esac
    pause_cleanup || break
  done
  echo "ERROR: RDS cleanup deadline exhausted."
  return 1
}

owned_rds_resource() {
  local missing="$1" resource="$2" status arn
  shift 2
  aws_call "${missing}" rds "$@"
  status=$?
  ((status == 0)) || return "${status}"
  arn="${AWS_OUTPUT}"
  if [[ "${arn}" != arn:* ]]; then
    echo "ERROR: Missing ${resource} ARN; refusing deletion."
    return 1
  fi
  aws_call '' rds list-tags-for-resource --resource-name "${arn}" \
    --query "TagList[?Key=='BuildID'].Value | [0]" --output text || return 1
  if [[ "${AWS_OUTPUT}" != "${BUILD_ID}" ]]; then
    echo "ERROR: ${resource} BuildID mismatch; refusing deletion."
    return 1
  fi
}

delete_instance() {
  local instance="$1" status
  owned_rds_resource DBInstanceNotFound instance describe-db-instances \
    --db-instance-identifier "${instance}" --query 'DBInstances[0].DBInstanceArn' --output text
  status=$?
  ((status != 2)) || return 0
  ((status == 0)) || return 1
  aws_call DBInstanceNotFound rds delete-db-instance --db-instance-identifier "${instance}" --skip-final-snapshot
  status=$?
  ((status != 2)) || return 0
  ((status == 0)) || return 1
  while true; do
    aws_call DBInstanceNotFound rds describe-db-instances --db-instance-identifier "${instance}" \
      --query 'DBInstances[0].DBInstanceStatus' --output text
    status=$?
    ((status != 2)) || return 0
    ((status == 0)) || return 1
    pause_cleanup || return 1
  done
}

delete_subnet_group() {
  local group="$1" status
  owned_rds_resource DBSubnetGroupNotFoundFault subnet-group describe-db-subnet-groups \
    --db-subnet-group-name "${group}" --query 'DBSubnetGroups[0].DBSubnetGroupArn' --output text
  status=$?
  ((status != 2)) || return 0
  ((status == 0)) || return 1
  aws_call DBSubnetGroupNotFoundFault rds delete-db-subnet-group --db-subnet-group-name "${group}"
  status=$?
  ((status == 0 || status == 2))
}

delete_security_group() {
  local group="$1" status
  aws_call InvalidGroup.NotFound ec2 describe-security-groups --group-ids "${group}" \
    --query "SecurityGroups[0].Tags[?Key=='BuildID'].Value | [0]" --output text
  status=$?
  ((status != 2)) || return 0
  ((status == 0)) || return 1
  if [[ "${AWS_OUTPUT}" != "${BUILD_ID}" ]]; then
    echo "ERROR: Security group BuildID mismatch; refusing deletion."
    return 1
  fi
  aws_call InvalidGroup.NotFound ec2 delete-security-group --group-id "${group}"
  status=$?
  ((status == 0 || status == 2))
}

echo "Starting ownership-checked RDS cleanup (40-minute deadline)..."
for resource in instance-id subnet-group security-group-id; do
  if [[ ! -f "${SHARED_DIR}/rds-${resource}" ]]; then
    echo "No ${resource} recorded; skipping."
    continue
  fi
  RESOURCE_ID=$(cat "${SHARED_DIR}/rds-${resource}")
  if [[ -z "${RESOURCE_ID}" ]]; then
    echo "ERROR: Empty recorded ${resource}; refusing deletion."
    CLEANUP_EXIT_CODE=1
    continue
  fi
  case "${resource}" in
    instance-id) delete_instance "${RESOURCE_ID}" ;;
    subnet-group) delete_subnet_group "${RESOURCE_ID}" ;;
    security-group-id) delete_security_group "${RESOURCE_ID}" ;;
  esac
  if [[ $? -ne 0 ]]; then
    CLEANUP_EXIT_CODE=1
  else
    echo "${resource} cleanup complete."
  fi
done
exit "${CLEANUP_EXIT_CODE}"
