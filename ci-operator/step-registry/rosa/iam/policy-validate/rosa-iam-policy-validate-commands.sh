#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Configure AWS credentials from the cluster profile
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
else
  echo "ERROR: AWS credentials file not found at ${AWSCRED}"
  exit 1
fi

export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"

echo "=== ROSA IAM Policy Validation ==="
echo "Region: ${AWS_DEFAULT_REGION}"
echo "Release version: ${RELEASE_VERSION}"

# Directory for artifacts
RESULTS_DIR="${ARTIFACT_DIR}/iam-policy-validation"
mkdir -p "${RESULTS_DIR}"

# --- Run IAM Policy Simulation ---
# Policies are auto-fetched from managed-cluster-config and matched against
# CredentialsRequests extracted from the release image.
echo ""
echo "--- Running IAM Policy Simulation ---"

# Generate JUnit XML for CI
osdctl iampermissions simulate \
  --release-version "${RELEASE_VERSION}" \
  --output junit \
  --output-file "${RESULTS_DIR}/iam-policy-results.xml" \
  --region "${AWS_DEFAULT_REGION}" 2>&1 || FAILED=1

# Also generate table output for human readability in logs
osdctl iampermissions simulate \
  --release-version "${RELEASE_VERSION}" \
  --output table \
  --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true

echo ""
echo "=== Validation Complete ==="
echo "JUnit XML results saved to: ${RESULTS_DIR}/"

if [[ "${FAILED:-0}" -eq 1 ]]; then
  echo "ERROR: One or more IAM policy validations failed. See results above."
  exit 1
fi

echo "All IAM policy validations passed."
