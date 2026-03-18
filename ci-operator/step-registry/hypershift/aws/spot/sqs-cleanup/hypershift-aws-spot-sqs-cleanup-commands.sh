#!/bin/bash

set -o nounset
set -o pipefail
set -o xtrace

# This step cleans up the SQS queue and EventBridge rules created by
# hypershift-aws-spot-sqs-setup. Best-effort cleanup; errors are logged
# but do not fail the job.

AWS_CREDS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
AWS_REGION="${AWS_REGION:-us-east-1}"

export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDS_FILE}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

# Read state from setup step
QUEUE_URL=""
RULE_PREFIX=""

if [[ -f "${SHARED_DIR}/spot_sqs_queue_url" ]]; then
  QUEUE_URL=$(cat "${SHARED_DIR}/spot_sqs_queue_url")
fi

if [[ -f "${SHARED_DIR}/spot_eventbridge_rule_prefix" ]]; then
  RULE_PREFIX=$(cat "${SHARED_DIR}/spot_eventbridge_rule_prefix")
fi

# Clean up EventBridge rules
if [[ -n "${RULE_PREFIX}" ]]; then
  echo "Cleaning up EventBridge rules with prefix: ${RULE_PREFIX}"

  for SUFFIX in interruption rebalance; do
    RULE_NAME="${RULE_PREFIX}-${SUFFIX}"
    echo "Removing targets and deleting rule: ${RULE_NAME}"
    aws events remove-targets --rule "${RULE_NAME}" --ids 1 --region "${AWS_REGION}" 2>/dev/null || true
    aws events delete-rule --name "${RULE_NAME}" --region "${AWS_REGION}" 2>/dev/null || true
  done

  echo "EventBridge rules cleaned up"
fi

# Clean up SQS queue
if [[ -n "${QUEUE_URL}" ]]; then
  echo "Deleting SQS queue: ${QUEUE_URL}"
  aws sqs delete-queue --queue-url "${QUEUE_URL}" --region "${AWS_REGION}" 2>/dev/null || true
  echo "SQS queue deleted"
fi

echo "Spot SQS cleanup complete"
