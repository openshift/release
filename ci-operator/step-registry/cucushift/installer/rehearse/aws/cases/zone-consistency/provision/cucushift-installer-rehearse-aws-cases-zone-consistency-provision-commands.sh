#!/bin/bash

# OCPBUGS-69923 - Verify control plane machine zone allocation consistency in manifests
# Run 10 iterations to verify CAPI and MAPI zone allocation is deterministic
#
# IMPORTANT: Must compare CORRECT files:
# - CAPI zones: cluster-api/machines/10_inframachine_*-master-*.yaml (from subnet filter)
# - MAPI zones: openshift/99_openshift-cluster-api_master-machines-*.yaml (availabilityZone)
#
# NOTE: openshift/99_openshift-cluster-api_master-machines-*.yaml is MAPI (despite the name)!

set -o errexit
set -o pipefail
set -o nounset

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

WORK_DIR="/tmp/test-zone-consistency"

echo "openshift-install version:"
openshift-install version
echo ""

TOTAL_FAILURES=0

for iteration in $(seq 1 10); do
  echo "=========================================="
  echo "Iteration $iteration/10"
  echo "=========================================="

  # Clean up everything from previous iteration
  rm -rf "${WORK_DIR}"
  mkdir -p "${WORK_DIR}"

  # Create install-config.yaml (without specifying zones - triggers the bug path)
  cat > "${WORK_DIR}/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  replicas: 3
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  replicas: 3
platform:
  aws:
    region: ${REGION}
pullSecret: >
  ${PULL_SECRET}
sshKey: |
  ${SSH_PUB_KEY}
EOF

  # Generate manifests (this consumes install-config.yaml)
  openshift-install create manifests --dir "${WORK_DIR}"

  # Extract CAPI zones from cluster-api/machines/10_inframachine_*-master-*.yaml
  # These are the REAL CAPI AWSMachine objects (not the misleadingly named openshift/99_openshift-cluster-api_* files)
  capi_zones=""
  while IFS= read -r file; do
    # Extract zone from subnet filter name (e.g., "cluster-subnet-private-us-east-1a" -> "us-east-1a")
    subnet_name=$(yq-go r "$file" 'spec.subnet.filters[0].values[0]' 2>/dev/null || echo "")
    # Extract zone from subnet name using region pattern
    zone=$(echo "$subnet_name" | grep -oE "${REGION}[a-z]$" || echo "")
    if [ -n "$zone" ] && [ "$zone" != "null" ]; then
      capi_zones="${capi_zones} ${zone}"
    fi
  done < <(find "$WORK_DIR"/cluster-api/machines -name "10_inframachine_*-master-*.yaml" -type f 2>/dev/null | sort)
  capi_zones=$(echo "$capi_zones" | xargs)

  # Extract MAPI zones from Machine objects
  # Files: openshift/99_openshift-cluster-api_master-machines-*.yaml
  # NOTE: Despite the "cluster-api" in the filename, these are MAPI Machine objects!
  mapi_zones=""
  while IFS= read -r file; do
    zone=$(yq-go r "$file" 'spec.providerSpec.value.placement.availabilityZone' 2>/dev/null || echo "")
    if [ -n "$zone" ] && [ "$zone" != "null" ]; then
      mapi_zones="${mapi_zones} ${zone}"
    fi
  done < <(find "$WORK_DIR"/openshift -name "99_openshift-cluster-api_master-machines-*.yaml" -type f 2>/dev/null | sort)
  mapi_zones=$(echo "$mapi_zones" | xargs)

  # Save manifests to ARTIFACT_DIR for verification (regardless of test result)
  iteration_artifact_dir="${ARTIFACT_DIR}/iteration-${iteration}"
  mkdir -p "${iteration_artifact_dir}"

  echo "  Saving manifests to ${iteration_artifact_dir}..."

  # Copy CAPI machine manifests
  if [ -d "$WORK_DIR/cluster-api/machines" ]; then
    cp -r "$WORK_DIR/cluster-api/machines" "${iteration_artifact_dir}/capi-machines"
  fi

  # Copy MAPI machine manifests
  mapi_manifest_dir="${iteration_artifact_dir}/mapi-machines"
  mkdir -p "${mapi_manifest_dir}"
  while IFS= read -r file; do
    cp "$file" "${mapi_manifest_dir}/"
  done < <(find "$WORK_DIR"/openshift -name "99_openshift-cluster-api_master-machines-*.yaml" -type f 2>/dev/null)

  # Compare
  echo "  CAPI zones (from cluster-api/machines/10_inframachine_*): $capi_zones"
  echo "  MAPI zones (from openshift/99_openshift-cluster-api_master-machines-*): $mapi_zones"

  if [ "$capi_zones" = "$mapi_zones" ]; then
    echo "  PASS"
  else
    echo "  FAIL: zones mismatch - CAPI and MAPI have different zone assignments"

    # Print detailed zone differences
    echo "  ERROR DETAILS:"
    IFS=' ' read -ra capi_array <<< "$capi_zones"
    IFS=' ' read -ra mapi_array <<< "$mapi_zones"

    for i in "${!capi_array[@]}"; do
      capi_zone="${capi_array[$i]:-}"
      mapi_zone="${mapi_array[$i]:-}"
      if [ "$capi_zone" != "$mapi_zone" ]; then
        echo "    Position $((i+1)): CAPI has '$capi_zone' but MAPI has '$mapi_zone'"
      fi
    done

    # Handle case where arrays have different lengths
    if [ ${#capi_array[@]} -ne ${#mapi_array[@]} ]; then
      echo "    Zone count mismatch: CAPI has ${#capi_array[@]} zones, MAPI has ${#mapi_array[@]} zones"
    fi

    TOTAL_FAILURES=$((TOTAL_FAILURES + 1))
  fi

  # Delete all generated files for next iteration
  rm -rf "${WORK_DIR}"
done

echo ""
echo "=========================================="
echo "Final Result: 10 iterations completed"
echo "CAPI and MAPI manifests saved to ${ARTIFACT_DIR}/ for verification"
if [ $TOTAL_FAILURES -eq 0 ]; then
  echo "PASS: All iterations have consistent zone allocation between CAPI and MAPI"
else
  echo "FAIL: $TOTAL_FAILURES iterations had zone mismatches (OCPBUGS-69923)"
fi
echo "=========================================="

exit $TOTAL_FAILURES
