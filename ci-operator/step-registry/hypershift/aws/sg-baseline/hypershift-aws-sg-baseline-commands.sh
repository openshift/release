#!/bin/bash

set -euo pipefail

echo "--- Recording security group baseline ---"

export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
export AWS_DEFAULT_REGION="${HYPERSHIFT_AWS_REGION}"

# Install AWS CLI
if ! command -v aws &>/dev/null; then
  echo "Installing AWS CLI..."
  pushd /tmp
  curl -sSfL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
  unzip -q awscliv2.zip
  ./aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli
  popd
fi

# Record all vpce-private-router security groups
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*-vpce-private-router" \
  --query "SecurityGroups[].GroupId" \
  --output text | tr '\t' '\n' | sort > "${SHARED_DIR}/sg-baseline.txt"

BASELINE_COUNT=$(wc -l < "${SHARED_DIR}/sg-baseline.txt" | tr -d ' ')
echo "[INFO] Recorded ${BASELINE_COUNT} existing vpce-private-router security groups as baseline"
cat "${SHARED_DIR}/sg-baseline.txt"
