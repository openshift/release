#!/bin/bash

set -euo pipefail

echo "--- Recording security group baseline ---"

export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
export AWS_DEFAULT_REGION="${HYPERSHIFT_AWS_REGION}"

# Record all vpce-private-router security groups
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*-vpce-private-router" \
  --query "SecurityGroups[].GroupId" \
  --output text | tr '\t' '\n' | sort > "${SHARED_DIR}/sg-baseline.txt"

BASELINE_COUNT=$(wc -l < "${SHARED_DIR}/sg-baseline.txt" | tr -d ' ')
echo "[INFO] Recorded ${BASELINE_COUNT} existing vpce-private-router security groups as baseline"
cat "${SHARED_DIR}/sg-baseline.txt"
