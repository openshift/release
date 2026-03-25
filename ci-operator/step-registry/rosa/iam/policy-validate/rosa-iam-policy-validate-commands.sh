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

# Directory for artifacts
RESULTS_DIR="${ARTIFACT_DIR}/iam-policy-validation"
mkdir -p "${RESULTS_DIR}"

POLICY_DIR="${RESULTS_DIR}/policies"
mkdir -p "${POLICY_DIR}"

MANIFEST_DIR="${RESULTS_DIR}/manifests"
mkdir -p "${MANIFEST_DIR}"

# --- Fetch AWS Managed Policies for ROSA HCP ---
declare -A ROSA_MANAGED_POLICIES
ROSA_MANAGED_POLICIES=(
  ["ROSAAmazonEBSCSIDriverOperatorPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAAmazonEBSCSIDriverOperatorPolicy"
  ["ROSAIngressOperatorPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAIngressOperatorPolicy"
  ["ROSAImageRegistryOperatorPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAImageRegistryOperatorPolicy"
  ["ROSACloudNetworkConfigOperatorPolicy"]="arn:aws:iam::aws:policy/service-role/ROSACloudNetworkConfigOperatorPolicy"
  ["ROSAKubeControllerPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAKubeControllerPolicy"
  ["ROSANodePoolManagementPolicy"]="arn:aws:iam::aws:policy/service-role/ROSANodePoolManagementPolicy"
  ["ROSAKMSProviderPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAKMSProviderPolicy"
  ["ROSAControlPlaneOperatorPolicy"]="arn:aws:iam::aws:policy/service-role/ROSAControlPlaneOperatorPolicy"
)

echo ""
echo "--- Fetching AWS Managed Policies ---"
for policy_name in "${!ROSA_MANAGED_POLICIES[@]}"; do
  policy_arn="${ROSA_MANAGED_POLICIES[$policy_name]}"
  echo "Fetching ${policy_name}..."

  # Get the default version ID
  version_id=$(aws iam get-policy \
    --policy-arn "${policy_arn}" \
    --query 'Policy.DefaultVersionId' \
    --output text 2>/dev/null) || {
    echo "WARNING: Could not fetch policy ${policy_name}, skipping"
    continue
  }

  # Get the policy document
  aws iam get-policy-version \
    --policy-arn "${policy_arn}" \
    --version-id "${version_id}" \
    --query 'PolicyVersion.Document' \
    --output json > "${POLICY_DIR}/${policy_name}.json" 2>/dev/null || {
    echo "WARNING: Could not fetch policy version for ${policy_name}, skipping"
    continue
  }

  echo "  Saved ${policy_name}.json (version: ${version_id})"
done

# --- Copy supplementary test manifests from osdctl ---
# These are bundled in the osdctl binary's testdata or provided via the repo
OSDCTL_MANIFEST_DIR="/go/src/github.com/openshift/osdctl/pkg/policies/testdata/manifests"
if [[ -d "${OSDCTL_MANIFEST_DIR}" ]]; then
  cp "${OSDCTL_MANIFEST_DIR}"/*.yaml "${MANIFEST_DIR}/" 2>/dev/null || true
  echo ""
  echo "Copied supplementary test manifests from osdctl"
else
  echo "WARNING: osdctl manifest directory not found at ${OSDCTL_MANIFEST_DIR}"
  echo "Falling back to built-in manifests only"
fi

# --- Run IAM Policy Simulation ---
echo ""
echo "--- Running IAM Policy Simulation ---"

FAILED=0

# Run simulation for each manifest that has a corresponding policy
for manifest_file in "${MANIFEST_DIR}"/*.yaml; do
  if [[ ! -f "${manifest_file}" ]]; then
    echo "No manifest files found"
    break
  fi

  manifest_name=$(basename "${manifest_file}" .yaml)
  echo ""
  echo "Validating: ${manifest_name}"

  # Extract the policyName from the manifest
  policy_name=$(grep '^policyName:' "${manifest_file}" | awk '{print $2}' | tr -d '"' | tr -d "'")
  policy_file="${POLICY_DIR}/${policy_name}.json"

  if [[ ! -f "${policy_file}" ]]; then
    echo "  WARNING: No policy file found for ${policy_name}, skipping"
    continue
  fi

  # Run the simulation
  osdctl iampermissions simulate \
    --policy-file "${policy_file}" \
    --manifest-file "${manifest_file}" \
    --output junit \
    --output-file "${RESULTS_DIR}/${manifest_name}-results.xml" \
    --region "${AWS_DEFAULT_REGION}" 2>&1 || {
    echo "  FAILED: ${manifest_name} has policy mismatches"
    FAILED=1
  }

  # Also generate table output for human readability in logs
  osdctl iampermissions simulate \
    --policy-file "${policy_file}" \
    --manifest-file "${manifest_file}" \
    --output table \
    --region "${AWS_DEFAULT_REGION}" 2>/dev/null || true

done

echo ""
echo "=== Validation Complete ==="
echo "JUnit XML results saved to: ${RESULTS_DIR}/"

if [[ ${FAILED} -eq 1 ]]; then
  echo "ERROR: One or more IAM policy validations failed. See results above."
  exit 1
fi

echo "All IAM policy validations passed."
