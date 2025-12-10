#!/bin/bash

# Script to create upgrade chaos test configuration files for a new OpenShift version
# Usage: ./create_upgrade_chaos_jobs.sh <target_version>
# Example: ./create_upgrade_chaos_jobs.sh 4.20
# This will create upgrade chaos tests for upgrading from 4.19 to 4.20

set -e

TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
    echo "Error: No target version provided"
    echo "Usage: $0 <target_version>"
    echo "Example: $0 4.20"
    exit 1
fi

PRIOR_VERSION=$(scripts/get_prior_minor_version.sh "$TARGET_VERSION")
INITIAL_VERSION=$(scripts/get_prior_minor_version.sh "$PRIOR_VERSION")

# Extract version numbers
TARGET_MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)
PRIOR_MINOR=$(echo "$PRIOR_VERSION" | cut -d. -f2)
INITIAL_MINOR=$(echo "$INITIAL_VERSION" | cut -d. -f2)

echo "Creating upgrade chaos test configurations..."
echo "  Upgrade path: ${PRIOR_VERSION} -> ${TARGET_VERSION}"
echo "  Based on: ${INITIAL_VERSION} -> ${PRIOR_VERSION}"

# Create upgrade chaos test config
UPGRADE_SOURCE="redhat-chaos-prow-scripts-main__${PRIOR_VERSION}-nightly-upgrade.yaml"
UPGRADE_TARGET="redhat-chaos-prow-scripts-main__${TARGET_VERSION}-nightly-upgrade.yaml"

if [ -f "$UPGRADE_SOURCE" ]; then
    # Replace version references
    sed -e "s/\"${INITIAL_VERSION}\"/\"${PRIOR_VERSION}\"/g" \
        -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
        -e "s/${INITIAL_MINOR}${PRIOR_MINOR}to${PRIOR_MINOR}${TARGET_MINOR}/${PRIOR_MINOR}${TARGET_MINOR}to${TARGET_MINOR}0/g" \
        -e "s/${INITIAL_VERSION}to${PRIOR_VERSION}/${PRIOR_VERSION}to${TARGET_VERSION}/g" \
        -e "s/TicketId ${PRIOR_MINOR}[0-9]*/TicketId ${TARGET_MINOR}0/g" \
        -e "s/cerberus-main-prow-${PRIOR_MINOR}[0-9]*-up/cerberus-main-prow-${TARGET_MINOR}0-up/g" \
        -e "s/prow-scripts-${INITIAL_MINOR}[0-9]*-up/prow-scripts-${PRIOR_MINOR}0-up/g" \
        -e "s/variant: ${PRIOR_VERSION}-nightly-upgrade/variant: ${TARGET_VERSION}-nightly-upgrade/g" \
        "$UPGRADE_SOURCE" > "$UPGRADE_TARGET"
    
    # Fix the double replacement issue for target version in releases
    sed -i '' -e "s/version: \"${TARGET_VERSION}\"\(.*\)# was ${PRIOR_VERSION}/version: \"${TARGET_VERSION}\"/g" "$UPGRADE_TARGET" 2>/dev/null || \
    sed -i -e "s/version: \"${TARGET_VERSION}\"\(.*\)# was ${PRIOR_VERSION}/version: \"${TARGET_VERSION}\"/g" "$UPGRADE_TARGET" 2>/dev/null || true
    
    echo "Created: $UPGRADE_TARGET"
else
    echo "Warning: Source file not found: $UPGRADE_SOURCE"
fi

echo ""
echo "Done! Created upgrade chaos test configurations for OCP ${TARGET_VERSION}"
echo ""
echo "Please verify the following in the new files:"
echo "  - Initial version (latest release) is ${PRIOR_VERSION}"
echo "  - Target version is ${TARGET_VERSION}"
echo "  - Job names reflect the correct upgrade path"
echo "  - variant in zz_generated_metadata is updated"

