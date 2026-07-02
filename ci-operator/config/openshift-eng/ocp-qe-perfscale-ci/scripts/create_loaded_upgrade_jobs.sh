#!/bin/bash

# Script to create AWS loaded upgrade configuration files for a new OpenShift version
# Usage: ./create_loaded_upgrade_jobs.sh <target_version>
# Example: ./create_loaded_upgrade_jobs.sh 4.24
# This creates upgrade configs for upgrading from 4.23 to 4.24

set -e

TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
    echo "Error: No target version provided"
    echo "Usage: $0 <target_version>"
    echo "Example: $0 4.24"
    exit 1
fi

# Calculate prior version (e.g., 4.24 -> 4.23)
TARGET_MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1)
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)
PRIOR_MINOR=$((TARGET_MINOR - 1))
PRIOR_VERSION="${TARGET_MAJOR}.${PRIOR_MINOR}"

# Calculate version before prior (e.g., 4.24 -> 4.23 -> 4.22)
PRIOR_PRIOR_MINOR=$((PRIOR_MINOR - 1))
PRIOR_PRIOR_VERSION="${TARGET_MAJOR}.${PRIOR_PRIOR_MINOR}"

echo "Creating AWS loaded upgrade configuration for OCP ${PRIOR_VERSION} → ${TARGET_VERSION}..."
echo "Based on: ${PRIOR_PRIOR_VERSION} → ${PRIOR_VERSION}"

# Define source and target filenames
SOURCE_FILE="openshift-eng-ocp-qe-perfscale-ci-main__aws-${PRIOR_VERSION}-nightly-x86-loaded-upgrade-from-${PRIOR_PRIOR_VERSION}.yaml"
TARGET_FILE="openshift-eng-ocp-qe-perfscale-ci-main__aws-${TARGET_VERSION}-nightly-x86-loaded-upgrade-from-${PRIOR_VERSION}.yaml"

# Check if source file exists
if [ ! -f "$SOURCE_FILE" ]; then
    echo "Error: Source file not found: $SOURCE_FILE"
    exit 1
fi

# Check if target file already exists
if [ -f "$TARGET_FILE" ]; then
    echo "Warning: Target file already exists: $TARGET_FILE"
    echo "Do you want to overwrite it? (y/n)"
    read -r response
    if [ "$response" != "y" ]; then
        echo "Aborted."
        exit 0
    fi
fi

# Create the new file with version replacements
# Need to update:
# 1. Initial version bounds (lower: 4.22.0-0 -> 4.23.0-0, upper: 4.23.0-0 -> 4.24.0-0)
# 2. Latest version (4.23 -> 4.24)
# 3. Variant in metadata
sed -e "s/lower: ${PRIOR_PRIOR_VERSION}.0-0/lower: ${PRIOR_VERSION}.0-0/g" \
    -e "s/upper: ${PRIOR_VERSION}.0-0/upper: ${TARGET_VERSION}.0-0/g" \
    -e "s/version: \"${PRIOR_VERSION}\"/version: \"${TARGET_VERSION}\"/g" \
    -e "s/variant: aws-${PRIOR_VERSION}-nightly-x86-loaded-upgrade-from-${PRIOR_PRIOR_VERSION}/variant: aws-${TARGET_VERSION}-nightly-x86-loaded-upgrade-from-${PRIOR_VERSION}/g" \
    "$SOURCE_FILE" > "$TARGET_FILE"

echo "Created: $TARGET_FILE"
echo ""
echo "Please verify the following in the new file:"
echo "  - releases.initial.version_bounds.lower is ${PRIOR_VERSION}.0-0"
echo "  - releases.initial.version_bounds.upper is ${TARGET_VERSION}.0-0"
echo "  - releases.latest.version is \"${TARGET_VERSION}\""
echo "  - zz_generated_metadata.variant is aws-${TARGET_VERSION}-nightly-x86-loaded-upgrade-from-${PRIOR_VERSION}"
echo "  - Review cron schedules (they may need manual adjustment to avoid conflicts)"
echo ""

# Navigate to release repo root and run make update
echo "Running 'make jobs' to generate Prow jobs..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"

cd "${RELEASE_ROOT}"
make jobs

echo ""
echo "✅ Done! Generated configuration and Prow jobs for ${PRIOR_VERSION} → ${TARGET_VERSION} upgrade"
echo ""
echo "Next steps:"
echo "  1. Review the generated files"
echo "  2. Commit and create a PR"
