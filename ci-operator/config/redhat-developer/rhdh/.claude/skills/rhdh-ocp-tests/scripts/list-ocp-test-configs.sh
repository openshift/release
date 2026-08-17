#!/usr/bin/env bash
# List OCP versions used in RHDH CI test configs, extracted from cluster_claim.version.
#
# The source of truth for which OCP version a test uses is its cluster_claim.version
# field, NOT the test name. Some tests encode the version in the name
# (e.g., e2e-ocp-v4-19-helm-nightly) but many do not (e.g., e2e-ocp-helm-nightly
# uses OCP 4.18 via cluster_claim.version).
#
# Usage:
#   list-ocp-test-configs.sh                         # All branches
#   list-ocp-test-configs.sh --branch main           # Specific branch
#   list-ocp-test-configs.sh --config-dir <path>     # Custom config directory
#
# Must be run from the root of the openshift/release repository.
# Requires: yq (v4+)

set -euo pipefail

CI_CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"
FILTER_BRANCH=""
CONFIG_PREFIX="redhat-developer-rhdh-"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch|-b)
      FILTER_BRANCH="$2"
      shift 2
      ;;
    --config-dir|-d)
      CI_CONFIG_DIR="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 [--branch <name>] [--config-dir <path>]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$CI_CONFIG_DIR" ]]; then
  echo "ERROR: Config directory not found: ${CI_CONFIG_DIR}" >&2
  echo "Are you running from the root of the openshift/release repository?" >&2
  exit 1
fi

if ! command -v yq &>/dev/null; then
  echo "ERROR: yq (v4+) is required but not found" >&2
  exit 1
fi

# Derive prefix from directory path
# shellcheck disable=SC2206  # Intentional word-splitting on path separators (no spaces in paths)
dir_parts=(${CI_CONFIG_DIR//\// })
if [[ ${#dir_parts[@]} -ge 2 ]]; then
  CONFIG_PREFIX="${dir_parts[-2]}-${dir_parts[-1]}-"
fi

BRANCH_COUNT=0

for config_file in "${CI_CONFIG_DIR}/${CONFIG_PREFIX}"*.yaml; do
  [[ -f "$config_file" ]] || continue

  filename=$(basename "$config_file")
  branch="${filename#"${CONFIG_PREFIX}"}"
  branch="${branch%.yaml}"

  if [[ -n "$FILTER_BRANCH" && "$branch" != "$FILTER_BRANCH" ]]; then
    continue
  fi

  # Extract all tests that have a cluster_claim with a version
  entries=$(yq -o=json '.tests[] | select(.cluster_claim.version != null)' "$config_file" 2>/dev/null || true)

  if [[ -z "$entries" ]]; then
    continue
  fi

  BRANCH_COUNT=$((BRANCH_COUNT + 1))
  echo ""
  echo "=== Branch: ${branch} ==="
  echo "    File: ${config_file}"
  echo ""
  printf "  %-45s %-13s %-30s %-10s\n" \
    "TEST_NAME" "OCP_VERSION" "CRON" "OPTIONAL"
  printf "  %-45s %-13s %-30s %-10s\n" \
    "---------" "-----------" "----" "--------"

  yq -o=json -I=0 '[.tests[] | select(.cluster_claim.version != null)]' "$config_file" 2>/dev/null | \
    jq -r '.[] | [
      .as,
      .cluster_claim.version,
      (.cron // "N/A"),
      (.optional // false | tostring)
    ] | @tsv' | sort -t$'\t' -k2 -V | \
    while IFS=$'\t' read -r name ver cron opt; do
      printf "  %-45s %-13s %-30s %-10s\n" "$name" "$ver" "$cron" "$opt"
    done

  # Show deduplicated OCP versions for this branch
  ocp_versions=$(yq -o=json -I=0 '[.tests[] | select(.cluster_claim.version != null) | .cluster_claim.version] | unique | sort_by(split(".") | map(tonumber))' "$config_file" 2>/dev/null | jq -r '.[]')
  echo ""
  echo "  OCP versions tested: $(echo "$ocp_versions" | tr '\n' ' ')"
done

echo ""
echo "---"
echo "Branches scanned: ${BRANCH_COUNT}" >&2
echo "Config directory: ${CI_CONFIG_DIR}" >&2
