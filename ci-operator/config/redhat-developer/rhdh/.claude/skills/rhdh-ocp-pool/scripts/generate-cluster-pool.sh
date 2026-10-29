#!/usr/bin/env bash
# Generate a new RHDH Hive ClusterPool YAML for a target OCP version.
#
# The imageSetRef is looked up from existing cluster pools across the entire
# openshift/release repository (not just RHDH pools) to ensure alignment.
# If no pool for the target version exists anywhere in the repo, the script
# errors out rather than guessing a patch version.
#
# Usage:
#   generate-cluster-pool.sh --version 4.22
#   generate-cluster-pool.sh --version 4.22 --reference 4.21
#   generate-cluster-pool.sh --version 4.22 --pool-dir <path> --all-pools-dir <path>
#
# Must be run from the root of the openshift/release repository.
# Requires: yq (v4+)

set -euo pipefail

POOL_DIR="clusters/hosted-mgmt/hive/pools/rhdh"
ALL_POOLS_DIR="clusters/hosted-mgmt/hive/pools"
OCP_VERSION=""
REFERENCE_VERSION=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      OCP_VERSION="$2"
      shift 2
      ;;
    --reference|-r)
      REFERENCE_VERSION="$2"
      shift 2
      ;;
    --pool-dir|-d)
      POOL_DIR="$2"
      shift 2
      ;;
    --all-pools-dir)
      ALL_POOLS_DIR="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Usage: $0 --version X.Y [--reference X.Y] [--dry-run] [--pool-dir <path>] [--all-pools-dir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$OCP_VERSION" ]]; then
  echo "ERROR: --version is required (e.g., --version 4.22)" >&2
  exit 1
fi

if ! echo "$OCP_VERSION" | grep -qE '^[0-9]+\.[0-9]+$'; then
  echo "ERROR: Version must be in X.Y format (e.g., 4.22), got: ${OCP_VERSION}" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq (v4+) is required but not found" >&2
  exit 1
fi

if [[ ! -d "$POOL_DIR" ]]; then
  echo "ERROR: Pool directory not found: ${POOL_DIR}" >&2
  exit 1
fi

MAJOR="${OCP_VERSION%%.*}"
MINOR="${OCP_VERSION#*.}"
NEXT_MINOR=$((MINOR + 1))
DASH_VER="${MAJOR}-${MINOR}"
TARGET_FILE="${POOL_DIR}/rhdh-ocp-${DASH_VER}-0-amd64-aws-us-east-2_clusterpool.yaml"

# Check if target already exists
if [[ -f "$TARGET_FILE" ]]; then
  echo "ERROR: Cluster pool already exists: ${TARGET_FILE}" >&2
  exit 1
fi

# ---------------------------------------------------------------
# 1. Find the imageSetRef from existing pools across the ENTIRE repo
# ---------------------------------------------------------------
echo "Looking up imageSetRef for OCP ${OCP_VERSION} across ${ALL_POOLS_DIR}/ ..." >&2

# Search all cluster pool YAML files for an imageSetRef matching the target version
IMAGE_SET_REF=""
if [[ -d "$ALL_POOLS_DIR" ]]; then
  IMAGE_SET_REF=$(grep -rh "name: ocp-release-${MAJOR}\.${MINOR}\." \
    "${ALL_POOLS_DIR}/" --include="*_clusterpool.yaml" 2>/dev/null | \
    sed 's/^[[:space:]]*//' | sed 's/^name: //' | \
    sort -V | tail -1 || true)
fi

if [[ -z "$IMAGE_SET_REF" ]]; then
  echo "ERROR: No existing cluster pool in the repo uses OCP ${OCP_VERSION}." >&2
  echo "Cannot determine the correct imageSetRef. A ClusterImageSet for ${OCP_VERSION}" >&2
  echo "must exist on the cluster before a pool can be created." >&2
  echo "" >&2
  echo "Check if OCP ${OCP_VERSION} has been released and image sets have been" >&2
  echo "added to the repo. You can search with:" >&2
  echo "  grep -r 'ocp-release-${MAJOR}.${MINOR}' ${ALL_POOLS_DIR}/" >&2
  exit 1
fi

echo "Found imageSetRef: ${IMAGE_SET_REF}" >&2

# ---------------------------------------------------------------
# 2. Find the reference RHDH pool to use as template
# ---------------------------------------------------------------
if [[ -n "$REFERENCE_VERSION" ]]; then
  REF_MAJOR="${REFERENCE_VERSION%%.*}"
  REF_MINOR="${REFERENCE_VERSION#*.}"
  REF_FILE="${POOL_DIR}/rhdh-ocp-${REF_MAJOR}-${REF_MINOR}-0-amd64-aws-us-east-2_clusterpool.yaml"
  if [[ ! -f "$REF_FILE" ]]; then
    echo "ERROR: Reference pool not found: ${REF_FILE}" >&2
    exit 1
  fi
else
  # Use the latest existing RHDH pool as template
  REF_FILE=$(find "$POOL_DIR" -name '*_clusterpool.yaml' -type f | sort -V | tail -1)
  if [[ -z "$REF_FILE" ]]; then
    echo "ERROR: No existing cluster pool files found in ${POOL_DIR}" >&2
    exit 1
  fi
  # Extract reference version from the file
  REFERENCE_VERSION=$(yq '.metadata.labels.version' "$REF_FILE" 2>/dev/null)
fi

echo "Using reference pool: $(basename "$REF_FILE") (OCP ${REFERENCE_VERSION})" >&2

# ---------------------------------------------------------------
# 3. Generate the new pool YAML
# ---------------------------------------------------------------

if $DRY_RUN; then
  # Dry-run: transform in a temp file, print to stdout, don't write to target
  WORK_FILE=$(mktemp)
  trap 'rm -f "$WORK_FILE"' EXIT
  cp "$REF_FILE" "$WORK_FILE"
else
  cp "$REF_FILE" "$TARGET_FILE"
  WORK_FILE="$TARGET_FILE"
fi

# Update version-specific fields
yq -i "
  .metadata.labels.version = \"${OCP_VERSION}\" |
  .metadata.labels.version_lower = \"${MAJOR}.${MINOR}.0-0\" |
  .metadata.labels.version_upper = \"${MAJOR}.${NEXT_MINOR}.0-0\" |
  .metadata.name = \"rhdh-${DASH_VER}-us-east-2\" |
  .spec.imageSetRef.name = \"${IMAGE_SET_REF}\" |
  .spec.size = 1 |
  .spec.maxSize = 2 |
  del(.spec.runningCount)
" "$WORK_FILE"

echo "" >&2
if $DRY_RUN; then
  echo "Dry-run: showing generated YAML (no file written)" >&2
  echo "Target would be: ${TARGET_FILE}" >&2
else
  echo "Generated: ${TARGET_FILE}" >&2
fi
echo "" >&2
echo "Fields set:" >&2
echo "  metadata.labels.version:      ${OCP_VERSION}" >&2
echo "  metadata.labels.version_lower: ${MAJOR}.${MINOR}.0-0" >&2
echo "  metadata.labels.version_upper: ${MAJOR}.${NEXT_MINOR}.0-0" >&2
echo "  metadata.name:                rhdh-${DASH_VER}-us-east-2" >&2
echo "  spec.imageSetRef.name:        ${IMAGE_SET_REF}" >&2
echo "  spec.size:                    1" >&2
echo "  spec.maxSize:                 2" >&2
echo "  spec.runningCount:            (removed — lean start)" >&2
echo "" >&2
echo "imageSetRef aligned with other pools in the repo." >&2

# Print the generated YAML to stdout
cat "$WORK_FILE"
