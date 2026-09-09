#!/usr/bin/env bash
# Generate a new e2e-ocp-vX-YY-helm-nightly test entry YAML block.
#
# Usage:
#   generate-test-entry.sh --version 4.22 --branch main
#   generate-test-entry.sh --version 4.22 --branch main --reference 4.21
#   generate-test-entry.sh --version 4.22 --branch release-1.9 --config-dir <path>
#
# Outputs the generated YAML block to stdout.
# Must be run from the root of the openshift/release repository.
# Requires: yq (v4+)

set -euo pipefail

CI_CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"
OCP_VERSION=""
BRANCH="main"
REFERENCE_VERSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      OCP_VERSION="$2"
      shift 2
      ;;
    --branch|-b)
      BRANCH="$2"
      shift 2
      ;;
    --reference|-r)
      REFERENCE_VERSION="$2"
      shift 2
      ;;
    --config-dir|-d)
      CI_CONFIG_DIR="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 --version X.Y --branch <name> [--reference X.Y] [--config-dir <path>]" >&2
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

# Derive config file path
# shellcheck disable=SC2206  # Intentional word-splitting on path separators (no spaces in paths)
dir_parts=(${CI_CONFIG_DIR//\// })
if [[ ${#dir_parts[@]} -lt 2 ]]; then
  echo "ERROR: --config-dir must contain at least two path components (got: ${CI_CONFIG_DIR})" >&2
  exit 1
fi
CONFIG_PREFIX="${dir_parts[-2]}-${dir_parts[-1]}-"
CONFIG_FILE="${CI_CONFIG_DIR}/${CONFIG_PREFIX}${BRANCH}.yaml"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
  exit 1
fi

MAJOR="${OCP_VERSION%%.*}"
MINOR="${OCP_VERSION#*.}"
NEW_DASH="${MAJOR}-${MINOR}"
NEW_TEST_NAME="e2e-ocp-v${NEW_DASH}-helm-nightly"

# Check if entry already exists
if yq -e ".tests[] | select(.as == \"${NEW_TEST_NAME}\")" "$CONFIG_FILE" &>/dev/null; then
  echo "ERROR: Test entry '${NEW_TEST_NAME}' already exists in ${CONFIG_FILE}" >&2
  exit 1
fi

# Find reference test entry
if [[ -n "$REFERENCE_VERSION" ]]; then
  REF_MAJOR="${REFERENCE_VERSION%%.*}"
  REF_MINOR="${REFERENCE_VERSION#*.}"
  REF_TEST_NAME="e2e-ocp-v${REF_MAJOR}-${REF_MINOR}-helm-nightly"
else
  # Find the latest versioned test entry
  REF_TEST_NAME=$(yq -r '.tests[].as' "$CONFIG_FILE" 2>/dev/null | \
    grep -E '^e2e-ocp-v[0-9]+-[0-9]+-helm-nightly$' | \
    sort -V | tail -1)
  if [[ -z "$REF_TEST_NAME" ]]; then
    echo "ERROR: No versioned OCP test entries found in ${CONFIG_FILE}" >&2
    exit 1
  fi
  REFERENCE_VERSION=$(echo "$REF_TEST_NAME" | sed -E 's/e2e-ocp-v([0-9]+)-([0-9]+)-helm-nightly/\1.\2/')
fi

# Check reference exists
if ! yq -e ".tests[] | select(.as == \"${REF_TEST_NAME}\")" "$CONFIG_FILE" &>/dev/null; then
  echo "ERROR: Reference test entry '${REF_TEST_NAME}' not found in ${CONFIG_FILE}" >&2
  AVAILABLE=$(yq -r '.tests[].as' "$CONFIG_FILE" 2>/dev/null | grep -E '^e2e-ocp-v[0-9]+-[0-9]+-helm-nightly$' || true)
  echo "Available versioned entries:" >&2
  echo "$AVAILABLE" >&2
  exit 1
fi

REF_MAJOR="${REFERENCE_VERSION%%.*}"
REF_MINOR="${REFERENCE_VERSION#*.}"

# Extract the reference entry and substitute version values
echo "# Generated test entry for OCP ${OCP_VERSION}"
echo "# Based on: ${REF_TEST_NAME} (OCP ${REFERENCE_VERSION})"
echo "# Config file: ${CONFIG_FILE}"
echo "# Insert this block into the 'tests:' list before 'zz_generated_metadata:'"
echo "#"
echo "# Fields changed from reference:"
echo "#   as: ${REF_TEST_NAME} -> ${NEW_TEST_NAME}"
echo "#   cluster_claim.version: \"${REFERENCE_VERSION}\" -> \"${OCP_VERSION}\""
echo "#   steps.env.OC_CLIENT_VERSION: stable-${REFERENCE_VERSION} -> stable-${OCP_VERSION}"
echo ""

yq -o=yaml "[.tests[] | select(.as == \"${REF_TEST_NAME}\")]" "$CONFIG_FILE" | \
  sed "s|as: ${REF_TEST_NAME}|as: ${NEW_TEST_NAME}|g" | \
  sed "s|version: \"${REFERENCE_VERSION}\"|version: \"${OCP_VERSION}\"|g" | \
  sed "s|OC_CLIENT_VERSION: stable-${REFERENCE_VERSION}|OC_CLIENT_VERSION: stable-${OCP_VERSION}|g"
