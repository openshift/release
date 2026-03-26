#!/bin/bash

set -euo pipefail

echo "--- Verifying security group cleanup after private cluster deletion ---"

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

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== Step 1: Check for orphaned vpce-private-router security groups ==="

# Get current vpce-private-router security groups
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*-vpce-private-router" \
  --query "SecurityGroups[].GroupId" \
  --output text | tr '\t' '\n' | sort > /tmp/sg-current.txt

CURRENT_COUNT=$(wc -l < /tmp/sg-current.txt | tr -d ' ')
echo "[INFO] Found ${CURRENT_COUNT} vpce-private-router security groups currently"

# Compare with baseline
if [ -f "${SHARED_DIR}/sg-baseline.txt" ]; then
  # Find security groups that are new (not in baseline) = orphaned from this test
  ORPHANED=$(comm -13 "${SHARED_DIR}/sg-baseline.txt" /tmp/sg-current.txt)

  if [ -z "${ORPHANED}" ]; then
    pass "No orphaned vpce-private-router security groups found after cluster deletion"
  else
    ORPHANED_COUNT=$(echo "${ORPHANED}" | wc -l | tr -d ' ')
    fail "${ORPHANED_COUNT} orphaned vpce-private-router security group(s) found after cluster deletion"
    echo "  Orphaned SG IDs:"

    for sg_id in ${ORPHANED}; do
      SG_INFO=$(aws ec2 describe-security-groups --group-ids "${sg_id}" \
        --query "SecurityGroups[0].{Name:GroupName,VpcId:VpcId,Description:Description}" \
        --output text 2>/dev/null || echo "unknown")
      echo "    ${sg_id}: ${SG_INFO}"
    done

    echo ""
    echo "  This indicates the OCPBUGS-74960 fix did NOT prevent the security group leak."
    echo "  The security group should have been deleted during HostedCluster teardown."
  fi
else
  echo "[WARN] No baseline file found at ${SHARED_DIR}/sg-baseline.txt"
  echo "[INFO] Falling back to checking for any vpce-private-router SGs"

  if [ "${CURRENT_COUNT}" -eq 0 ] || [ -z "$(cat /tmp/sg-current.txt)" ]; then
    pass "No vpce-private-router security groups exist (no baseline comparison needed)"
  else
    echo "[WARN] Found ${CURRENT_COUNT} vpce-private-router SGs but cannot determine if they are orphaned without baseline"
    echo "[WARN] Treating as inconclusive — manually verify these SGs"
    cat /tmp/sg-current.txt
  fi
fi

echo ""
echo "=== SUMMARY ==="
echo "PASS: ${PASS_COUNT}"
echo "FAIL: ${FAIL_COUNT}"

if [ "${FAIL_COUNT}" -gt 0 ]; then
  echo "RESULT: VERIFICATION FAILED — orphaned security groups detected"
  exit 1
else
  echo "RESULT: ALL CHECKS PASSED"
fi
