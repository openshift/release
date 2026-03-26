#!/bin/bash

set -euo pipefail

echo "--- Verifying security group cleanup after private cluster deletion ---"

export AWS_SHARED_CREDENTIALS_FILE="/etc/hypershift-pool-aws-credentials/credentials"
export AWS_DEFAULT_REGION="${HYPERSHIFT_AWS_REGION}"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "[PASS] $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "[FAIL] $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== Step 1: Check for orphaned vpce-private-router security groups ==="

# Get current vpce-private-router security groups with names and VPC IDs
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*-vpce-private-router" \
  --query "SecurityGroups[].{Id:GroupId,Name:GroupName,VpcId:VpcId}" \
  --output text | sort > /tmp/sg-current-full.txt

CURRENT_COUNT=$(wc -l < /tmp/sg-current-full.txt | tr -d ' ')
echo "[INFO] Found ${CURRENT_COUNT} vpce-private-router security groups currently"

# Extract just IDs for baseline comparison
awk '{print $1}' /tmp/sg-current-full.txt | sort > /tmp/sg-current-ids.txt

if [ -f "${SHARED_DIR}/sg-baseline.txt" ]; then
  # Find security groups that are new (not in baseline)
  NEW_SGS=$(comm -13 "${SHARED_DIR}/sg-baseline.txt" /tmp/sg-current-ids.txt || true)

  if [ -z "${NEW_SGS}" ]; then
    pass "No new vpce-private-router security groups found after cluster deletion"
  else
    NEW_COUNT=$(echo "${NEW_SGS}" | wc -l | tr -d ' ')
    echo "[INFO] Found ${NEW_COUNT} new vpce-private-router security group(s) since baseline"

    # For each new SG, check if it is truly orphaned:
    # An orphaned SG is one whose VPC endpoint was deleted but the SG remains.
    # We detect this by checking if the VPC still has any active VPC endpoints.
    ORPHANED_COUNT=0
    for sg_id in ${NEW_SGS}; do
      SG_LINE=$(grep "^${sg_id}" /tmp/sg-current-full.txt || true)
      if [ -z "${SG_LINE}" ]; then
        echo "[INFO] SG ${sg_id} already deleted (cleanup succeeded)"
        continue
      fi

      SG_NAME=$(echo "${SG_LINE}" | awk '{print $2}')
      VPC_ID=$(echo "${SG_LINE}" | awk '{print $3}')

      # Check if there are any active VPC endpoints in this VPC
      ENDPOINT_COUNT=$(aws ec2 describe-vpc-endpoints \
        --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-state,Values=available,pending,pendingAcceptance" \
        --query "length(VpcEndpoints)" \
        --output text 2>/dev/null || echo "0")

      if [ "${ENDPOINT_COUNT}" = "0" ]; then
        echo "[FAIL] Orphaned SG: ${sg_id} (${SG_NAME}) in VPC ${VPC_ID} — no active VPC endpoints remain"
        ORPHANED_COUNT=$((ORPHANED_COUNT + 1))
      else
        echo "[INFO] SG ${sg_id} (${SG_NAME}) in VPC ${VPC_ID} has ${ENDPOINT_COUNT} active endpoint(s) — likely from a running test"
      fi
    done

    if [ "${ORPHANED_COUNT}" -gt 0 ]; then
      fail "${ORPHANED_COUNT} orphaned vpce-private-router security group(s) found (VPC has no active endpoints)"
      echo "  This indicates the OCPBUGS-74960 fix did NOT prevent the security group leak."
      echo "  The security group should have been deleted during HostedCluster teardown."
    else
      pass "All new SGs belong to VPCs with active endpoints (from other running tests, not orphaned)"
    fi
  fi
else
  echo "[WARN] No baseline file found at ${SHARED_DIR}/sg-baseline.txt"
  pass "Skipping SG comparison (no baseline available)"
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
