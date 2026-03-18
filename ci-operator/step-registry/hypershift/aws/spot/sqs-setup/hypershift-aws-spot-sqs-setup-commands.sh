#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# This step creates the SQS queue and EventBridge rules needed for the
# AWS Node Termination Handler spot instance e2e test.
#
# The queue name matches the hardcoded value in the hypershift e2e test:
#   test/e2e/nodepool_spot_termination_handler_test.go
#
# Uses hypershift-pool-aws-credentials which is the same credential
# the e2e test binary uses to discover the queue.

AWS_CREDS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
AWS_REGION="${AWS_REGION:-us-east-1}"
QUEUE_NAME="${SQS_QUEUE_NAME:-agarcial-nth-queue}"

export AWS_SHARED_CREDENTIALS_FILE="${AWS_CREDS_FILE}"
export AWS_DEFAULT_REGION="${AWS_REGION}"

echo "Creating SQS queue: ${QUEUE_NAME} in region ${AWS_REGION}"

# Create the queue (idempotent - returns existing queue if it already exists)
QUEUE_URL=$(aws sqs create-queue --queue-name "${QUEUE_NAME}" --region "${AWS_REGION}" --query 'QueueUrl' --output text)
echo "Queue URL: ${QUEUE_URL}"

# Get the queue ARN
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" --attribute-names QueueArn --region "${AWS_REGION}" --query 'Attributes.QueueArn' --output text)
echo "Queue ARN: ${QUEUE_ARN}"

# Set queue policy to allow EventBridge to send messages
POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sqs:SendMessage",
      "Resource": "${QUEUE_ARN}"
    }
  ]
}
EOF
)

aws sqs set-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attributes "Policy=$(echo "${POLICY}" | jq -c .)" \
  --region "${AWS_REGION}"

echo "SQS queue policy updated"

# Create EventBridge rule for Spot Instance Interruption Warning
RULE_PREFIX="hypershift-ci-spot-${PROW_JOB_ID:0:10}"

aws events put-rule \
  --name "${RULE_PREFIX}-interruption" \
  --event-pattern '{"source":["aws.ec2"],"detail-type":["EC2 Spot Instance Interruption Warning"]}' \
  --region "${AWS_REGION}" || true

aws events put-targets \
  --rule "${RULE_PREFIX}-interruption" \
  --targets "Id=1,Arn=${QUEUE_ARN}" \
  --region "${AWS_REGION}" || true

# Create EventBridge rule for EC2 Instance Rebalance Recommendation
aws events put-rule \
  --name "${RULE_PREFIX}-rebalance" \
  --event-pattern '{"source":["aws.ec2"],"detail-type":["EC2 Instance Rebalance Recommendation"]}' \
  --region "${AWS_REGION}" || true

aws events put-targets \
  --rule "${RULE_PREFIX}-rebalance" \
  --targets "Id=1,Arn=${QUEUE_ARN}" \
  --region "${AWS_REGION}" || true

echo "EventBridge rules created"

# Save state for cleanup
echo "${QUEUE_URL}" > "${SHARED_DIR}/spot_sqs_queue_url"
echo "${QUEUE_NAME}" > "${SHARED_DIR}/spot_sqs_queue_name"
echo "${RULE_PREFIX}" > "${SHARED_DIR}/spot_eventbridge_rule_prefix"

echo "SQS queue and EventBridge rules setup complete"
