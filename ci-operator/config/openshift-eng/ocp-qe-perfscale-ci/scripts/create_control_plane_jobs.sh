#!/bin/bash

# Script to create control-plane configuration files for a new OpenShift version
# Usage: ./create_control_plane_jobs.sh <target_version>
# Example: ./create_control_plane_jobs.sh 4.23

set -e

TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
    echo "Error: No target version provided"
    echo "Usage: $0 <target_version>"
    echo "Example: $0 4.23"
    exit 1
fi

# Calculate prior version (e.g., 4.23 -> 4.22)
TARGET_MAJOR=$(echo "$TARGET_VERSION" | cut -d. -f1)
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)
PRIOR_MINOR=$((TARGET_MINOR - 1))
PRIOR_VERSION="${TARGET_MAJOR}.${PRIOR_MINOR}"

echo "Creating control-plane configuration for OCP ${TARGET_VERSION} based on ${PRIOR_VERSION}..."

# Define source and target filenames
SOURCE_FILE="openshift-eng-ocp-qe-perfscale-ci-main__${PRIOR_VERSION}-nightly-control-plane.yaml"
TARGET_FILE="openshift-eng-ocp-qe-perfscale-ci-main__${TARGET_VERSION}-nightly-control-plane.yaml"

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
sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
    -e "s/variant: ${PRIOR_VERSION}-nightly-control-plane/variant: ${TARGET_VERSION}-nightly-control-plane/g" \
    "$SOURCE_FILE" > "$TARGET_FILE"

echo "Created: $TARGET_FILE"
echo ""
echo "Please verify the following in the new file:"
echo "  - base_images.upi-installer.name is \"${TARGET_VERSION}\""
echo "  - All releases.*.version are \"${TARGET_VERSION}\""
echo "  - zz_generated_metadata.variant is ${TARGET_VERSION}-nightly-control-plane"
echo "  - Review cron schedules (they may need manual adjustment to avoid conflicts)"
echo ""

# Navigate to release repo root and run make update
echo "Running 'make jobs' to generate Prow jobs..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"

cd "${RELEASE_ROOT}"
make jobs

echo ""
echo "✅ Done! Generated configuration and Prow jobs for OCP ${TARGET_VERSION}"
echo ""
echo "Next steps:"
echo "  1. Review the generated files"
echo "  2. Commit and create a PR"
