#!/usr/bin/env bash
# List all RHDH Hive ClusterPool configurations from local YAML files.
#
# Usage:
#   list-cluster-pools.sh                       # Default RHDH pool dir
#   list-cluster-pools.sh --pool-dir <path>     # Custom pool directory
#
# Must be run from the root of the openshift/release repository.
# Requires: yq (v4+)

set -euo pipefail

POOL_DIR="clusters/hosted-mgmt/hive/pools/rhdh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-dir|-d)
      POOL_DIR="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--pool-dir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$POOL_DIR" ]]; then
  echo "ERROR: Pool directory not found: ${POOL_DIR}" >&2
  echo "Are you running from the root of the openshift/release repository?" >&2
  exit 1
fi

# Check for yq
if ! command -v yq &>/dev/null; then
  echo "ERROR: yq (v4+) is required but not found" >&2
  exit 1
fi

# Find all cluster pool files
POOL_FILES=()
while IFS= read -r f; do
  POOL_FILES+=("$f")
done < <(find "$POOL_DIR" -name '*_clusterpool.yaml' -type f | sort)

if [[ ${#POOL_FILES[@]} -eq 0 ]]; then
  echo "No cluster pool files found in ${POOL_DIR}" >&2
  exit 0
fi

# Print table header
printf "%-10s %-25s %-6s %-6s %-8s %-65s %s\n" \
  "VERSION" "POOL_NAME" "SIZE" "MAX" "RUNNING" "IMAGE_SET" "FILENAME"
printf "%-10s %-25s %-6s %-6s %-8s %-65s %s\n" \
  "-------" "---------" "----" "---" "-------" "---------" "--------"

# Parse each pool file and output a row
# Collect output into an array for sorting
declare -a ROWS=()

for pool_file in "${POOL_FILES[@]}"; do
  filename=$(basename "$pool_file")

  version=$(yq '.metadata.labels.version' "$pool_file" 2>/dev/null || echo "unknown")
  pool_name=$(yq '.metadata.name' "$pool_file" 2>/dev/null || echo "unknown")
  size=$(yq '.spec.size // 0' "$pool_file" 2>/dev/null || echo "0")
  max_size=$(yq '.spec.maxSize // 0' "$pool_file" 2>/dev/null || echo "0")
  running=$(yq '.spec.runningCount // 0' "$pool_file" 2>/dev/null || echo "0")
  image_set=$(yq '.spec.imageSetRef.name // "N/A"' "$pool_file" 2>/dev/null || echo "N/A")

  ROWS+=("$(printf "%-10s %-25s %-6s %-6s %-8s %-65s %s" \
    "$version" "$pool_name" "$size" "$max_size" "$running" "$image_set" "$filename")")
done

# Sort by version and print
printf '%s\n' "${ROWS[@]}" | sort -t. -k1,1n -k2,2n

# Print summary to stderr
echo "" >&2
echo "Total pools: ${#POOL_FILES[@]}" >&2
echo "Pool directory: ${POOL_DIR}" >&2
